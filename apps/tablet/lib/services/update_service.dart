import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'kiosk_bridge.dart';

/// In-app updater backed by GitHub Releases.
///
/// Flow:
///   1. [check] hits the GitHub REST API for the latest published
///      release of [owner]/[repo] and parses `tag_name` ("v1.0.5") +
///      the asset list.
///   2. Compares the release's version (parsed from the tag) against
///      the current `package_info.buildNumber`. Returns null if we're
///      already up-to-date.
///   3. [downloadAndInstall] streams the matching ABI asset to local
///      storage, then hands the file to [KioskBridge.installApk] which
///      runs PackageInstaller on the native side.
///
/// The GitHub API allows 60 unauthenticated requests/hour per IP —
/// plenty for the manual "check for updates" tap in the service menu.
class UpdateService {
  UpdateService({required this.owner, required this.repo});

  /// GitHub repository — e.g. `Samat1989` / `smartvend-tablet`. APK
  /// assets must be attached to a published Release; pre-releases
  /// can be opted into with [allowPrereleases].
  final String owner;
  final String repo;

  /// Per-architecture asset name we pick from the release. The
  /// android-arm split is the only one we ship to current hardware
  /// (Unisoc SC9832E). If a future device needs a different ABI we
  /// can extend this with a per-CPU lookup against `Platform.version`
  /// or a Dart isolate that runs `getprop ro.product.cpu.abilist`.
  static const String assetName = 'app-armeabi-v7a-release.apk';

  /// Latest release info if available + newer than current.
  /// Returns null when:
  ///   • Current version is >= the published tag's version
  ///   • The matching ABI asset isn't attached to the release
  ///   • The network call fails (caller surfaces the error string)
  Future<UpdateInfo?> check({bool allowPrereleases = false}) async {
    final url = Uri.parse('https://api.github.com/repos/$owner/$repo/releases');
    final resp = await http.get(url, headers: {
      'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
    }).timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      throw HttpException('GitHub API ${resp.statusCode}: ${resp.body}');
    }
    final list = jsonDecode(resp.body) as List;
    final pick = list.firstWhere(
      (r) {
        // The repo is shared with the esp-relay firmware, whose releases are
        // tagged "relay-vX.Y.Z". Skip them — they carry no APK and must not
        // shadow the latest tablet release.
        final tag = (r['tag_name'] as String?) ?? '';
        if (tag.startsWith('relay-')) return false;
        return allowPrereleases || (r['prerelease'] == false);
      },
      orElse: () => null,
    );
    if (pick == null) return null;

    final tag = (pick['tag_name'] as String?) ?? '';
    final version = _parseVersion(tag);
    if (version == null) return null;

    final assets = (pick['assets'] as List?) ?? const [];
    final asset = assets.firstWhere(
      (a) => (a['name'] as String?)?.toLowerCase() == assetName.toLowerCase(),
      orElse: () => null,
    );
    if (asset == null) return null;

    final info = await PackageInfo.fromPlatform();
    final current = int.tryParse(info.buildNumber) ?? 0;

    return UpdateInfo(
      tagName: tag,
      versionName: version.name,
      versionCode: version.code,
      currentVersionName: info.version,
      currentVersionCode: current,
      assetUrl: asset['browser_download_url'] as String,
      assetSize: (asset['size'] as num?)?.toInt() ?? 0,
      body: pick['body'] as String? ?? '',
      publishedAt: pick['published_at'] as String? ?? '',
    );
  }

  /// Download the release asset to the app's cache dir and hand it to
  /// the native installer. [onProgress] fires per chunk with bytes
  /// received vs total — drive a progress bar with it.
  Future<void> downloadAndInstall(
    UpdateInfo info, {
    void Function(int received, int total)? onProgress,
  }) async {
    final cache = await getTemporaryDirectory();
    final dest = File('${cache.path}/update-${info.versionCode}.apk');
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

    debugPrint('[UpdateService] downloaded ${dest.lengthSync()} bytes to ${dest.path}');
    await KioskBridge.installApk(dest.path);
  }

  _ParsedVersion? _parseVersion(String tag) {
    // Accepted tag formats:
    //   v1.0.5          → name=1.0.5, code derived from version parts
    //   v1.0.5+1005     → name=1.0.5, code=1005 (matches pubspec.yaml)
    //   1.0.5+1005      → same, leading "v" is optional
    final cleaned = tag.replaceFirst(RegExp(r'^v'), '');
    final parts = cleaned.split('+');
    final name = parts.first;
    if (name.isEmpty) return null;
    int code;
    if (parts.length >= 2) {
      code = int.tryParse(parts[1]) ?? 0;
    } else {
      // Derive a monotonic int from the dotted version when no
      // explicit build number is given. 1.0.5 → 10005.
      final dots = name.split('.').map(int.tryParse).toList();
      if (dots.any((n) => n == null)) return null;
      code = dots[0]! * 10000 +
          (dots.length > 1 ? dots[1]! * 100 : 0) +
          (dots.length > 2 ? dots[2]! : 0);
    }
    return _ParsedVersion(name: name, code: code);
  }
}

class _ParsedVersion {
  _ParsedVersion({required this.name, required this.code});
  final String name;
  final int code;
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

  bool get isNewer => versionCode > currentVersionCode;

  /// Pretty file size for the confirmation dialog.
  String get assetSizeHuman {
    if (assetSize <= 0) return '?';
    final mb = assetSize / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} МБ';
  }
}
