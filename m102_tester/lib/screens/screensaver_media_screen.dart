import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/media_service.dart';
import '../services/strings.dart';

/// Service-mode "Заставка" screen — surfaces:
///   • the on-device folder the attract loop scans for media,
///   • the list of currently-loaded files,
///   • a Refresh button (re-scans the folder), and
///   • a per-file Delete button.
///
/// The folder lives under `/Android/data/<pkg>/files/media/` so the
/// operator can `adb push` files in or browse to it via any file
/// manager (Files by Google, MiXplorer, etc.) and drop new content
/// without needing root or storage permissions.
class ScreensaverMediaScreen extends StatefulWidget {
  const ScreensaverMediaScreen({super.key});

  @override
  State<ScreensaverMediaScreen> createState() => _ScreensaverMediaScreenState();
}

class _ScreensaverMediaScreenState extends State<ScreensaverMediaScreen> {
  bool _importing = false;

  /// Opens the system file picker (Android's SAF) so the operator can
  /// grab files from internal storage, a plugged-in USB stick, or any
  /// cloud provider exposed as a document provider. Each picked file
  /// is copied into the app's media folder so the screensaver picks
  /// it up on the next refresh.
  Future<void> _addFiles() async {
    final media = context.read<MediaService>();
    final folder = media.folderPath;
    if (folder == null || _importing) return;
    setState(() => _importing = true);
    try {
      final result = await FilePicker.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: const [
          'jpg', 'jpeg', 'png', 'webp', 'gif',
          'mp4', 'mov', 'webm', 'mkv',
        ],
      );
      if (result == null || result.files.isEmpty) return;
      var copied = 0;
      for (final f in result.files) {
        final src = f.path;
        if (src == null) continue;
        try {
          final destPath = '$folder${Platform.pathSeparator}${f.name}';
          await File(src).copy(destPath);
          copied++;
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Не удалось скопировать ${f.name}: $e')),
            );
          }
        }
      }
      await media.refresh();
      if (mounted && copied > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Добавлено файлов: $copied')),
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final media = context.watch<MediaService>();
    return Scaffold(
      backgroundColor: Colors.grey.shade900,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          s.t('service_screensaver_media'),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: media.isScanning ? null : media.refresh,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: _importing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.add),
        label: const Text('Добавить'),
        onPressed: _importing ? null : _addFiles,
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Папка с медиа на устройстве',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    media.folderPath ?? '(не доступна)',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Копируйте сюда .jpg / .png / .webp / .gif или '
                    '.mp4 / .mov / .webm / .mkv через adb push или '
                    'файловый менеджер, потом нажмите «обновить» сверху.',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: media.items.isEmpty
                  ? Center(
                      child: Text(
                        media.isScanning
                            ? 'Сканирование…'
                            : 'Медиа-файлов пока нет',
                        style: const TextStyle(color: Colors.white54),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: media.items.length,
                      itemBuilder: (ctx, i) {
                        final it = media.items[i];
                        return ListTile(
                          leading: Icon(
                            it.kind == MediaKind.video
                                ? Icons.movie_outlined
                                : Icons.image_outlined,
                            color: Colors.white70,
                          ),
                          title: Text(
                            it.filename,
                            style: const TextStyle(
                              color: Colors.white,
                              fontFamily: 'monospace',
                              fontSize: 13,
                            ),
                          ),
                          subtitle: Text(
                            it.kind == MediaKind.video ? 'видео' : 'изображение',
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline,
                                color: Colors.redAccent),
                            onPressed: () async {
                              try {
                                await File(it.path).delete();
                              } catch (_) {}
                              await media.refresh();
                            },
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
