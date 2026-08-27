import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'kiosk_bridge.dart';

/// In-app updater backed by a manifest in Supabase Storage.
///
/// Flow:
///   1. [check] GETs [manifestUrl] — a small JSON describing exactly one
///      release — and compares its `code` against the installed
///      `package_info.buildNumber`. Returns null if we're already current.
///   2. [downloadAndInstall] streams the APK the manifest points at to
///      local storage, then hands the file to [KioskBridge.installApk],
///      which runs PackageInstaller on the native side.
///
/// This used to read the GitHub Releases API, and most of the complexity it
/// has shed came from one fact: a GitHub repo is a SINGLE tag namespace
/// shared with the esp-pulse and esp-relay firmware streams. That forced a
/// tag-shape whitelist here (a blacklist had already broken once, when the
/// new pulse stream sat at the top of /releases carrying no APK), tag
/// prefixes on every stream, and a two-step /tags dance in the firmware.
///
/// Storage has paths instead: `updates/tablet/` is ours alone, and the
/// manifest describes one release, so there is nothing to filter. Adding the
/// firmware streams later cannot disturb this — they get their own
/// directories and their own manifests.
class UpdateService {
  UpdateService({required this.manifestUrl});

  /// Public URL of `updates/tablet/manifest.json`, written by
  /// scripts/release_tablet.py. The bucket is public, so no auth here.
  final String manifestUrl;

  /// What the manifest currently advertises, alongside what is installed.
  ///
  /// Always non-null on success — ask [UpdateInfo.isNewer] whether it is
  /// worth installing, so the service menu can show "up to date" with the
  /// two versions side by side instead of an empty result.
  ///
  /// Throws on a failed fetch or a malformed manifest; the caller surfaces
  /// the message. The nullable return type is kept because the caller still
  /// has a "no releases" branch from the GitHub era.
  Future<UpdateInfo?> check() async {
    // Cache-busting query: Storage serves objects through a CDN, and while
    // the manifest is uploaded with a 60 s max-age, an intermediate proxy on
    // the machine's network is under no obligation to respect it.
    final url = Uri.parse(manifestUrl).replace(queryParameters: {
      't': DateTime.now().millisecondsSinceEpoch.toString(),
    });
    final resp = await http
        .get(url, headers: {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw HttpException('Manifest ${resp.statusCode}: ${resp.body}');
    }

    final m = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final versionName = (m['version'] as String?)?.trim() ?? '';
    final assetUrl = (m['url'] as String?)?.trim() ?? '';
    // `code` is the SHIPPED versionCode — the release script writes the
    // post-ABI-offset number (pubspec build + 1000 for armeabi-v7a), because
    // that is what the installed APK reports and what we compare against.
    final versionCode = (m['code'] as num?)?.toInt() ?? 0;
    if (versionName.isEmpty || assetUrl.isEmpty || versionCode == 0) {
      throw const FormatException('manifest missing version/code/url');
    }

    final info = await PackageInfo.fromPlatform();
    return UpdateInfo(
      tagName: 'v$versionName+$versionCode',
      versionName: versionName,
      versionCode: versionCode,
      currentVersionName: info.version,
      currentVersionCode: int.tryParse(info.buildNumber) ?? 0,
      assetUrl: assetUrl,
      assetSize: (m['size'] as num?)?.toInt() ?? 0,
      body: m['notes'] as String? ?? '',
      publishedAt: m['published_at'] as String? ?? '',
    );
  }

  /// Download the release APK and return the saved path.
  ///
  /// [manual] picks the destination: `false` → private cache (feeds the
  /// automatic PackageInstaller session), `true` → the app's EXTERNAL
  /// files dir (`Android/data/<pkg>/files`) — visible to file managers,
  /// so the operator can install the file by hand if the automatic
  /// flow is blocked on their ROM.
  Future<String> downloadApk(
    UpdateInfo info, {
    void Function(int received, int total)? onProgress,
    bool manual = false,
  }) async {
    final dir = manual
        ? (await getExternalStorageDirectory() ??
            await getTemporaryDirectory())
        : await getTemporaryDirectory();
    final name = manual
        ? 'microvend-${info.versionName}.apk'
        : 'update-${info.versionCode}.apk';
    final dest = File('${dir.path}/$name');
    if (await dest.exists()) await dest.delete();

    final req = http.Request('GET', Uri.parse(info.assetUrl))
      ..followRedirects = true
      ..headers['Accept'] = 'application/octet-stream';
    final streamed = await req.send().timeout(const Duration(seconds: 30));
    if (streamed.statusCode != 200) {
      throw HttpException('Download HTTP ${streamed.statusCode}');
    }

    final total = streamed.contentLength ?? info.assetSize;
    final sink = dest.openWrite();
    var received = 0;
    await for (final chunk in streamed.stream) {
      sink.add(chunk);
      received += chunk.length;
      onProgress?.call(received, total);
    }
    await sink.flush();
    await sink.close();

    debugPrint(
        '[UpdateService] downloaded ${dest.lengthSync()} bytes to ${dest.path}');
    return dest.path;
  }

  /// Download to cache and hand the file to the automatic native
  /// installer (PackageInstaller session).
  Future<void> downloadAndInstall(
    UpdateInfo info, {
    void Function(int received, int total)? onProgress,
  }) async {
    final path = await downloadApk(info, onProgress: onProgress);
    await KioskBridge.installApk(path);
  }

}

/// Compare two dotted version names ("1.1.5" vs "1.1.3").
/// Returns >0 when [a] is newer, <0 when older, 0 when equal. Missing or
/// non-numeric components count as 0, so "1.1" == "1.1.0".
int _compareVersionNames(String a, String b) {
  final pa = a.split('.');
  final pb = b.split('.');
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final na = i < pa.length ? int.tryParse(pa[i].trim()) ?? 0 : 0;
    final nb = i < pb.length ? int.tryParse(pb[i].trim()) ?? 0 : 0;
    if (na != nb) return na - nb;
  }
  return 0;
}

/// Available update — what the operator confirms before download.
class UpdateInfo {
  UpdateInfo({
    required this.tagName,
    required this.versionName,
    required this.versionCode,
    required this.currentVersionName,
    required this.currentVersionCode,
    required this.assetUrl,
    required this.assetSize,
    required this.body,
    required this.publishedAt,
  });

  final String tagName;
  final String versionName;
  final int versionCode;
  final String currentVersionName;
  final int currentVersionCode;
  final String assetUrl;
  final int assetSize;
  final String body;
  final String publishedAt;

  /// True when this release is newer than what's installed.
  ///
  /// Compares the *semantic version name* (1.1.5 vs 1.1.3) first. The build
  /// code (`+NNNN`) has historically been assigned inconsistently across
  /// releases — a higher version name could carry a lower build code (e.g.
  /// v1.1.5+3015 vs an installed 1.1.3+4013), which a pure code comparison
  /// would wrongly treat as "no update". The build code is only the
  /// tie-breaker when the version names are identical.
  bool get isNewer {
    final cmp = _compareVersionNames(versionName, currentVersionName);
    if (cmp != 0) return cmp > 0;
    return versionCode > currentVersionCode;
  }

  /// Pretty file size for the confirmation dialog.
  String get assetSizeHuman {
    if (assetSize <= 0) return '?';
    final mb = assetSize / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} МБ';
  }
}
