import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One PackageInstaller session status, mirrored from the native side
/// (`InstallReceiver`). Status values are Android's
/// `PackageInstaller.EXTRA_STATUS` constants: -1 = pending user action
/// (confirm dialog shown), 0 = success, 1..7 = failure codes, 100 =
/// our synthetic "confirm dialog failed to launch".
class InstallStatus {
  const InstallStatus(this.status, this.message);

  final int status;
  final String message;

  bool get isPendingUserAction => status == -1;
  bool get isFailure => status > 0;
}

/// What this particular tablet's firmware and provisioning allow.
///
/// Read once from the native side, which probes for the RY firmware by
/// asking whether `persist.sys.navbar.disabled` exists at all. The service
/// menu uses this to grey out actions that would otherwise be buttons that
/// silently do nothing on a tablet from a different supplier.
class KioskCapabilities {
  const KioskCapabilities({
    required this.vendorBars,
    required this.vendorReboot,
    required this.deviceOwner,
    required this.firmware,
  });

  /// Firmware owns the system bars — «Показать навбар» is meaningful.
  final bool vendorBars;

  /// Firmware reboots on request, no permission needed.
  final bool vendorReboot;

  /// App is provisioned as device owner: silent lock task, DPM reboot.
  final bool deviceOwner;

  /// `Build.DISPLAY`, shown in diagnostics so a technician can say which
  /// tablet is in front of them without opening Settings.
  final String firmware;

  /// Nothing works and nothing is claimed — the state before the first
  /// answer arrives, and the answer itself on a plain tablet with no owner.
  static const unknown = KioskCapabilities(
    vendorBars: false,
    vendorReboot: false,
    deviceOwner: false,
    firmware: '',
  );

  /// Whether [KioskBridge.rebootDevice] has any path to take.
  bool get canReboot => deviceOwner || vendorReboot;
}

/// Thin wrapper over the native kiosk MethodChannel exposed by
/// `MainActivity`. The Android side handles lock-task / immersive
/// mode automatically — the only thing the Flutter side needs to
/// trigger is the "operator wants out" escape hatch.
class KioskBridge {
  static const _channel = MethodChannel('kz.smartvend/kiosk');

  /// ANDROID_ID of this tablet, or null when the ROM withholds it.
  /// Used as the identity behind the machine claim — see
  /// [DeviceStorage.deviceId] for how the fallback works.
  static Future<String?> androidId() async {
    try {
      final v = await _channel.invokeMethod<String>('androidId');
      return (v == null || v.isEmpty) ? null : v;
    } catch (_) {
      return null;
    }
  }

  /// Lazily installs a handler on the channel that listens for callbacks
  /// the native side pushes back to us (currently only `usbPermissionResult`
  /// from [MainActivity.usbPermissionReceiver]). Calling this multiple
  /// times is safe — only one handler is registered.
  static bool _handlersInstalled = false;
  static final _usbPermissionCtrl = StreamController<bool>.broadcast();
  static final _installStatusCtrl =
      StreamController<InstallStatus>.broadcast();

  /// Fires `true` when the user accepted the system "Allow USB access?"
  /// dialog and `false` when they cancelled. [BoardClient] listens here
  /// and retries [autoConnect] on `true` so the operator never has to
  /// tap a "reconnect" button after granting permission.
  static Stream<bool> get usbPermissionResultStream {
    _installHandlersIfNeeded();
    return _usbPermissionCtrl.stream;
  }

  /// PackageInstaller session statuses pushed by the native side
  /// during a self-update. The update screen listens so a stalled or
  /// failed install is explained on screen instead of hanging.
  static Stream<InstallStatus> get installStatusStream {
    _installHandlersIfNeeded();
    return _installStatusCtrl.stream;
  }

  static void _installHandlersIfNeeded() {
    if (_handlersInstalled) return;
    _handlersInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'usbPermissionResult') {
        final args = call.arguments;
        final granted = args is Map ? args['granted'] == true : false;
        debugPrint('[KioskBridge] usbPermissionResult granted=$granted');
        _usbPermissionCtrl.add(granted);
      }
      if (call.method == 'installStatus') {
        final args = call.arguments;
        final status =
            args is Map ? (args['status'] as num?)?.toInt() ?? 1 : 1;
        final message =
            args is Map ? (args['message'] as String? ?? '') : '';
        debugPrint('[KioskBridge] installStatus $status "$message"');
        _installStatusCtrl.add(InstallStatus(status, message));
      }
      return null;
    });
  }

  /// Stop lock-task and launch the system Settings activity. Used by
  /// the service menu so the operator can join Wi-Fi, install OS
  /// updates, etc. The app returns to lock-task automatically on its
  /// next resume.
  static Future<void> exitToAndroid() async {
    await _channel.invokeMethod<void>('exitToAndroid');
  }

  /// Kill the current process and relaunch [MainActivity] in ~250 ms
  /// via the system AlarmManager. Mirrors the factory app's `m933reboot(4)`
  /// / `m933reboot(9)` — used to clear stuck USB-Serial driver state
  /// when the board has been silent through multiple reconnect cycles.
  /// Works without device-owner.
  static Future<void> restartApp() async {
    await _channel.invokeMethod<void>('restartApp');
  }

  /// Hard reboot the whole Android device. The native side tries
  /// DevicePolicyManager first and falls back to the RY firmware's
  /// `android.intent.action.shouhj.REBOOT` broadcast, which needs no
  /// permission at all — the same call the factory app makes for its
  /// nightly maintenance restart. Throws
  /// `PlatformException(code: 'reboot_failed')` only when neither path
  /// exists, which is a tablet that is neither owned nor RY firmware;
  /// callers fall back to [restartApp] or just log.
  static Future<void> rebootDevice() async {
    await _channel.invokeMethod<void>('rebootDevice');
  }

  /// Ask the native side what this tablet can do. Cached after the first
  /// answer — a ROM does not change under a running app, and the probe
  /// forks a `getprop` process.
  ///
  /// Never throws: an older build with no such method, or a non-Android
  /// host, both resolve to [KioskCapabilities.unknown], which disables the
  /// firmware-specific tiles rather than offering them on a guess.
  static KioskCapabilities? _caps;

  static Future<KioskCapabilities> capabilities() async {
    final cached = _caps;
    if (cached != null) return cached;
    try {
      final raw = await _channel
          .invokeMapMethod<String, dynamic>('firmwareCapabilities');
      final caps = raw == null
          ? KioskCapabilities.unknown
          : KioskCapabilities(
              vendorBars: raw['vendorBars'] == true,
              vendorReboot: raw['vendorReboot'] == true,
              deviceOwner: raw['deviceOwner'] == true,
              firmware: raw['firmware'] as String? ?? '',
            );
      _caps = caps;
      return caps;
    } catch (e) {
      debugPrint('[KioskBridge] capabilities unavailable: $e');
      _caps = KioskCapabilities.unknown;
      return KioskCapabilities.unknown;
    }
  }

  /// Hand the device back: drop device-owner status.
  ///
  /// `adb shell dpm remove-active-admin` refuses to touch a non-test-only
  /// owner, so for a release build this is the only way out short of a
  /// factory reset. Needed whenever a tablet changes machines or is retired
  /// — while the app owns the device it cannot even be uninstalled.
  ///
  /// Irreversible from the tablet's side: getting the rights back means adb
  /// or mmd_diag again, on a device with no accounts. Throws
  /// `PlatformException(code: 'not_device_owner')` when there was nothing
  /// to clear.
  static Future<void> clearDeviceOwner() async {
    await _channel.invokeMethod<void>('clearDeviceOwner');
    // The cached answer just became wrong in the one way that matters.
    _caps = null;
  }

  /// Whether this boot is the servicing session opened by
  /// [showNavBarAndReboot] — bars visible, notification shade usable.
  ///
  /// The native side decides once at activity start and keeps the answer for
  /// the life of the process, so this is a plain read. [main] asks before
  /// picking a [SystemUiMode]: Flutter hides the bars on its own, and a
  /// tablet that came back from «Показать навбар» would otherwise get the
  /// bars from the firmware and lose them again to the first frame.
  ///
  /// False on anything that is not this Android app.
  static Future<bool> serviceBarsSession() async {
    try {
      return await _channel.invokeMethod<bool>('serviceBarsSession') ?? false;
    } catch (e) {
      debugPrint('[KioskBridge] serviceBarsSession unavailable: $e');
      return false;
    }
  }

  /// Give the operator the Android navigation and status bars back for a
  /// single servicing session, then reboot into them.
  ///
  /// On SHENGMA/RY tablets the bars are not the app's to hide: the
  /// framework decides at display init from `persist.sys.navbar.disabled`
  /// and `persist.sys.statusbar.disabled`, so no amount of immersive can
  /// touch them. This flips both properties on and reboots.
  ///
  /// Returning the bar windows is only half of it: the app hides them again
  /// on every start (immersive here and natively, plus lock task, which
  /// refuses the pull-down outright — that is why the nav bar used to come
  /// back on its own and the shade never did). So the native side also
  /// records the session and spends that one boot standing aside; see
  /// [serviceBarsSession].
  ///
  /// The loan expires by itself. Every start of [MainActivity] re-sends
  /// STATUSBAR_OFF, so the reboot *after* this one comes back to a bare
  /// kiosk with nobody having to remember to switch it off — exactly how
  /// the factory app's own «показать навбар» setting behaves.
  ///
  /// Returns as the device is going down; there is no success to observe.
  /// A no-op on tablets whose ROM has no such handler.
  static Future<void> showNavBarAndReboot() async {
    await _channel.invokeMethod<void>('showNavBarAndReboot');
  }

  /// Install the APK at [path] via PackageInstaller. Device-owner
  /// kiosks (our default) install silently; non-owners see Android's
  /// "Allow this app to install unknown apps?" dialog once.
  ///
  /// Returns when the session is committed — actual install runs in
  /// the background and the app is killed + relaunched on success.
  static Future<void> installApk(String path) async {
    await _channel.invokeMethod<void>('installApk', {'path': path});
  }

  /// Hand a downloaded APK to the SYSTEM package-installer UI — the
  /// same flow as tapping the file in a file manager, which works even
  /// on ROMs where the PackageInstaller-session confirm dialog never
  /// surfaces. Kiosk pinning is dropped first on the native side; the
  /// operator then taps «Установить» in the familiar system dialog.
  static Future<void> openApk(String path) async {
    await _channel.invokeMethod<void>('openApk', {'path': path});
  }

  /// Force the Android "Allow this app to access USB device?" dialog
  /// to appear for the CH340 — even when the cable was plugged in
  /// before the app started (no [USB_DEVICE_ATTACHED] intent fired,
  /// so the system never auto-prompted).
  ///
  /// Returns one of:
  ///   * `'granted'`   — permission already held, the dialog was NOT
  ///                     shown. Caller can connect immediately.
  ///   * `'requested'` — dialog displayed, result will arrive via
  ///                     [usbPermissionResultStream].
  ///   * `'no_device'` — no CH340 attached, nothing to ask about.
  ///
  /// On non-Android platforms this returns `'no_device'`.
  static Future<String> requestUsbPermission() async {
    _installHandlersIfNeeded();
    try {
      final r = await _channel.invokeMethod<String>('requestUsbPermission');
      return r ?? 'no_device';
    } on PlatformException catch (e) {
      debugPrint('[KioskBridge] requestUsbPermission failed: ${e.message}');
      return 'no_device';
    }
  }
}
