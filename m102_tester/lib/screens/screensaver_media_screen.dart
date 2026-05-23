import 'dart:io';

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
class ScreensaverMediaScreen extends StatelessWidget {
  const ScreensaverMediaScreen({super.key});

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
