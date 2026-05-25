import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Helpers for the two "checksum" forms that Android QR provisioning
/// accepts:
///
///   * `PROVISIONING_DEVICE_ADMIN_SIGNATURE_CHECKSUM` — SHA-256 of the
///     APK's signing certificate, base64-url-safe encoded.
///     Recommended: the cert is stable across releases, so the same
///     QR keeps working when you bump the APK version.
///
///   * `PROVISIONING_DEVICE_ADMIN_PACKAGE_DOWNLOAD_CHECKSUM` — SHA-256
///     of the whole APK file. Tighter binding, but you'd need to
///     regenerate the QR on every release.
///
/// In the provisioning UI we collect the cert SHA-256 as colon-
/// separated hex (as keytool prints it), convert here.
class ChecksumHelper {
  /// Convert keytool's `XX:XX:…:XX` SHA-256 print into the base64
  /// URL-safe (no `=` padding) form Android expects for the signature
  /// checksum extra. Returns null on parse failure.
  static String? keytoolHexToBase64UrlSafe(String input) {
    final cleaned =
        input.replaceAll(':', '').replaceAll(RegExp(r'\s'), '').toLowerCase();
    if (cleaned.length != 64 || !RegExp(r'^[0-9a-f]+$').hasMatch(cleaned)) {
      return null;
    }
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = int.parse(cleaned.substring(i * 2, i * 2 + 2), radix: 16);
    }
    // Android wants base64 URL-safe without `=` padding.
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Compute SHA-256 of an in-memory APK and return as base64
  /// URL-safe (no padding). Used by the "fetch APK to verify"
  /// optional path — for the common GitHub Releases case the
  /// operator just pastes the keystore cert hash and skips the
  /// download.
  static String sha256BytesToBase64UrlSafe(List<int> apkBytes) {
    final digest = sha256.convert(apkBytes);
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }
}
