import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// One media file the screensaver should show. We don't open the
/// underlying file here — we just hand the path + kind down to the
/// screensaver, which spins up an [Image] or [VideoPlayer] on demand.
class MediaItem {
  const MediaItem({required this.path, required this.kind});

  final String path;
  final MediaKind kind;

  String get filename => path.split(Platform.pathSeparator).last;
}

enum MediaKind { image, video }

/// Looks for screensaver media in the app's external-files folder
/// (`/Android/data/kz.smartvend.m102_tester/files/media/`).
///
/// The operator can `adb push image.jpg /sdcard/Android/data/<pkg>/files/media/`
/// or copy via any file manager — the app rescans on every launch and
/// whenever [refresh] is called from the service menu.
///
/// Recognised extensions:
///   • images: .jpg .jpeg .png .webp .gif
///   • videos: .mp4 .mov .webm .mkv
///
/// Everything else is ignored.
class MediaService extends ChangeNotifier {
  MediaService() {
    refresh();
  }

  static const Set<String> _imageExt = {
    '.jpg', '.jpeg', '.png', '.webp', '.gif',
  };
  static const Set<String> _videoExt = {
    '.mp4', '.mov', '.webm', '.mkv',
  };

  List<MediaItem> _items = const [];
  bool _scanning = false;
  String? _folderPath;

  List<MediaItem> get items => List.unmodifiable(_items);
  bool get isScanning => _scanning;

  /// Absolute path of the folder being scanned. Useful for the service
  /// menu to show the operator where to copy files.
  String? get folderPath => _folderPath;

  Future<Directory?> _mediaDir() async {
    Directory? root;
    try {
      root = await getExternalStorageDirectory();
    } catch (e) {
      // App-private external storage isn't available on this device —
      // fall back to documents dir so the screensaver still works in
      // emulator / debug builds.
      root = await getApplicationDocumentsDirectory();
    }
    if (root == null) return null;
    final dir = Directory('${root.path}/media');
    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    } catch (_) {
      return null;
    }
    return dir;
  }

  Future<void> refresh() async {
    if (_scanning) return;
    _scanning = true;
    notifyListeners();
    try {
      final dir = await _mediaDir();
      if (dir == null) {
        _items = const [];
        _folderPath = null;
        return;
      }
      _folderPath = dir.path;
      final list = <MediaItem>[];
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.path.toLowerCase();
        final dot = name.lastIndexOf('.');
        if (dot < 0) continue;
        final ext = name.substring(dot);
        if (_imageExt.contains(ext)) {
          list.add(MediaItem(path: entity.path, kind: MediaKind.image));
        } else if (_videoExt.contains(ext)) {
          list.add(MediaItem(path: entity.path, kind: MediaKind.video));
        }
      }
      list.sort((a, b) => a.filename.compareTo(b.filename));
      _items = list;
    } finally {
      _scanning = false;
      notifyListeners();
    }
  }
}
