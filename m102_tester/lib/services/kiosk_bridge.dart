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
}
