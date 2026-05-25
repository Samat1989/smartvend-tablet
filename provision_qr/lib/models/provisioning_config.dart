import 'dart:convert';

/// All fields that go into the Android QR-Code-Provisioning payload.
///
/// Each property maps 1-to-1 onto a `DevicePolicyManager.EXTRA_*` key
/// the system reads from the QR JSON during the setup-wizard QR-scan
/// flow. Keys we don't emit are left blank in the QR — Android picks
/// sane defaults (English UTC, ask-for-Wi-Fi at first boot, etc.).
///
/// Full key reference:
/// https://developer.android.com/reference/android/app/admin/DevicePolicyManager
class ProvisioningConfig {
  ProvisioningConfig({
    this.adminComponent =
        'kz.smartvend.m102_tester/kz.smartvend.m102_tester.KioskAdminReceiver',
    this.apkDownloadUrl = '',
    this.signatureChecksumBase64 = '',
    this.wifiSsid = '',
    this.wifiPassword = '',
    this.wifiSecurityType = 'WPA',
    this.locale = 'ru_RU',
    this.timeZone = 'Asia/Almaty',
    this.skipEncryption = true,
    this.leaveAllSystemAppsEnabled = true,
  });

  /// `ComponentInfo{pkg/.Receiver}` of the DeviceAdminReceiver. For
  /// m102_tester this never changes — the Receiver lives at a fixed
  /// path inside the APK.
  String adminComponent;

  /// Direct HTTPS URL to the signed APK. Must be reachable from the
  /// tablet's first Wi-Fi connection. GitHub Release assets work fine
  /// (`https://github.com/.../releases/download/v1.0.X/app-armeabi-v7a-release.apk`).
  String apkDownloadUrl;

  /// SHA-256 of the **signing certificate** of the APK, base64
  /// URL-safe encoded (no padding `=`). Computed by `keytool -list`
  /// on `release.jks`. The tablet refuses to install an APK whose
  /// cert hash doesn't match — this is the security gate that
  /// prevents a man-in-the-middle from substituting a malicious APK.
  String signatureChecksumBase64;

  String wifiSsid;
  String wifiPassword;
  /// One of `NONE`, `WPA`, `WEP`, `EAP`. The tablet's setup wizard
  /// joins this network *before* downloading the APK.
  String wifiSecurityType;

  String locale;
  String timeZone;

  /// Skip device-encryption prompt during setup. Tablets are kiosks
  /// behind a locked panel — full-disk encryption brings a recurring
  /// boot password we don't want.
  bool skipEncryption;

  /// Keep system apps available (camera for QR scan in service mode,
  /// Settings for ADB pairing in emergencies). Disable to lock the
  /// device down harder.
  bool leaveAllSystemAppsEnabled;

  ProvisioningConfig copyWith({
    String? adminComponent,
    String? apkDownloadUrl,
    String? signatureChecksumBase64,
    String? wifiSsid,
    String? wifiPassword,
    String? wifiSecurityType,
    String? locale,
    String? timeZone,
    bool? skipEncryption,
    bool? leaveAllSystemAppsEnabled,
  }) =>
      ProvisioningConfig(
        adminComponent: adminComponent ?? this.adminComponent,
        apkDownloadUrl: apkDownloadUrl ?? this.apkDownloadUrl,
        signatureChecksumBase64:
            signatureChecksumBase64 ?? this.signatureChecksumBase64,
        wifiSsid: wifiSsid ?? this.wifiSsid,
        wifiPassword: wifiPassword ?? this.wifiPassword,
        wifiSecurityType: wifiSecurityType ?? this.wifiSecurityType,
        locale: locale ?? this.locale,
        timeZone: timeZone ?? this.timeZone,
        skipEncryption: skipEncryption ?? this.skipEncryption,
        leaveAllSystemAppsEnabled:
            leaveAllSystemAppsEnabled ?? this.leaveAllSystemAppsEnabled,
      );

  /// Encode to the QR payload JSON. Empty fields are dropped so the
  /// scanned blob stays compact (a 600-row QR is harder to read).
  Map<String, dynamic> toQrPayload() {
    final m = <String, dynamic>{
      'android.app.extra.PROVISIONING_DEVICE_ADMIN_COMPONENT_NAME':
          adminComponent,
      if (apkDownloadUrl.isNotEmpty)
        'android.app.extra.PROVISIONING_DEVICE_ADMIN_PACKAGE_DOWNLOAD_LOCATION':
            apkDownloadUrl,
      if (signatureChecksumBase64.isNotEmpty)
        'android.app.extra.PROVISIONING_DEVICE_ADMIN_SIGNATURE_CHECKSUM':
            signatureChecksumBase64,
      if (wifiSsid.isNotEmpty)
        'android.app.extra.PROVISIONING_WIFI_SSID': wifiSsid,
      if (wifiSsid.isNotEmpty && wifiSecurityType != 'NONE')
        'android.app.extra.PROVISIONING_WIFI_SECURITY_TYPE': wifiSecurityType,
      if (wifiPassword.isNotEmpty)
        'android.app.extra.PROVISIONING_WIFI_PASSWORD': wifiPassword,
      if (locale.isNotEmpty)
        'android.app.extra.PROVISIONING_LOCALE': locale,
      if (timeZone.isNotEmpty)
        'android.app.extra.PROVISIONING_TIME_ZONE': timeZone,
      'android.app.extra.PROVISIONING_SKIP_ENCRYPTION': skipEncryption,
      'android.app.extra.PROVISIONING_LEAVE_ALL_SYSTEM_APPS_ENABLED':
          leaveAllSystemAppsEnabled,
    };
    return m;
  }

  String toQrString() => jsonEncode(toQrPayload());

  /// Form completeness check — only the three "must-have" fields are
  /// required to produce a *useful* QR. The OS will accept the QR
  /// without Wi-Fi credentials but ask the operator at first boot.
  bool get isReady =>
      apkDownloadUrl.isNotEmpty &&
      signatureChecksumBase64.isNotEmpty &&
      adminComponent.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'adminComponent': adminComponent,
        'apkDownloadUrl': apkDownloadUrl,
        'signatureChecksumBase64': signatureChecksumBase64,
        'wifiSsid': wifiSsid,
        'wifiPassword': wifiPassword,
        'wifiSecurityType': wifiSecurityType,
        'locale': locale,
        'timeZone': timeZone,
        'skipEncryption': skipEncryption,
        'leaveAllSystemAppsEnabled': leaveAllSystemAppsEnabled,
      };

  static ProvisioningConfig fromJson(Map<String, dynamic> j) =>
      ProvisioningConfig(
        adminComponent: j['adminComponent'] as String? ??
            'kz.smartvend.m102_tester/kz.smartvend.m102_tester.KioskAdminReceiver',
        apkDownloadUrl: j['apkDownloadUrl'] as String? ?? '',
        signatureChecksumBase64: j['signatureChecksumBase64'] as String? ?? '',
        wifiSsid: j['wifiSsid'] as String? ?? '',
        wifiPassword: j['wifiPassword'] as String? ?? '',
        wifiSecurityType: j['wifiSecurityType'] as String? ?? 'WPA',
        locale: j['locale'] as String? ?? 'ru_RU',
        timeZone: j['timeZone'] as String? ?? 'Asia/Almaty',
        skipEncryption: j['skipEncryption'] as bool? ?? true,
        leaveAllSystemAppsEnabled:
            j['leaveAllSystemAppsEnabled'] as bool? ?? true,
      );
}
