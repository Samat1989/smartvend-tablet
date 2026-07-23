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

  /// Hard reboot the whole Android device via DevicePolicyManager.
  /// Requires the app to be device-owner — same provisioning we
  /// already need for the silent kiosk pinning. If we aren't owner,
  /// throws `PlatformException(code: 'not_device_owner')` which
  /// callers handle by falling back to [restartApp] or just logging.
  static Future<void> rebootDevice() async {
    await _channel.invokeMethod<void>('rebootDevice');
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
