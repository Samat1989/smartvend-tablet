import 'package:flutter/services.dart';

/// Thin wrapper over the native kiosk MethodChannel exposed by
/// `MainActivity`. The Android side handles lock-task / immersive
/// mode automatically — the only thing the Flutter side needs to
/// trigger is the "operator wants out" escape hatch.
class KioskBridge {
  static const _channel = MethodChannel('kz.smartvend/kiosk');

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
}
