import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Thin wrapper over the native kiosk MethodChannel exposed by
/// `MainActivity`. The Android side handles lock-task / immersive
/// mode automatically — the only thing the Flutter side needs to
/// trigger is the "operator wants out" escape hatch.
class KioskBridge {
  static const _channel = MethodChannel('kz.smartvend/kiosk');

  /// Lazily installs a handler on the channel that listens for callbacks
  /// the native side pushes back to us (currently only `usbPermissionResult`
  /// from [MainActivity.usbPermissionReceiver]). Calling this multiple
  /// times is safe — only one handler is registered.
  static bool _handlersInstalled = false;
  static final _usbPermissionCtrl = StreamController<bool>.broadcast();

  /// Fires `true` when the user accepted the system "Allow USB access?"
  /// dialog and `false` when they cancelled. [BoardClient] listens here
  /// and retries [autoConnect] on `true` so the operator never has to
  /// tap a "reconnect" button after granting permission.
  static Stream<bool> get usbPermissionResultStream {
    _installHandlersIfNeeded();
    return _usbPermissionCtrl.stream;
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

  /// Hard reboot the whole Android device via DevicePolicyManager.
  /// Requires the app to be device-owner — same provisioning we
  /// already need for the silent kiosk pinning. If we aren't owner,
  /// throws `PlatformException(code: 'not_device_owner')` which
  /// callers handle by falling back to [restartApp] or just logging.
  static Future<void> rebootDevice() async {
    await _channel.invokeMethod<void>('rebootDevice');
  }

  /// Privileged factory reset via [DevicePolicyManager.wipeData].
  /// Erases user data, factory-reset-protection (FRP), and external
  /// storage; preserves the system OS. The tablet reboots into the
  /// Welcome / Setup-Wizard screen — after which device-owner has to
  /// be re-set via ADB or QR provisioning before the kiosk is
  /// functional again.
  ///
  /// Returns immediately; the actual wipe happens a few seconds later
  /// while the native side returns control to Dart. There is **no
  /// way to undo** this — caller MUST surface a confirmation dialog
  /// before invoking.
  ///
  /// Throws `PlatformException(code: 'not_device_owner')` when the app
  /// hasn't been provisioned as device-owner.
  static Future<void> factoryReset() async {
    await _channel.invokeMethod<void>('factoryReset');
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
