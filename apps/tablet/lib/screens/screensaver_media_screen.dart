import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/device_storage.dart';
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
              SnackBar(
                  content: Text('${context.read<Strings>().t('media_copy_failed')} '
                      '${f.name}: $e')),
            );
          }
        }
      }
      await media.refresh();
      if (mounted && copied > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('${context.read<Strings>().t('media_added')} '
                  '$copied')),
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
        label: Text(s.t('media_add')),
        onPressed: _importing ? null : _addFiles,
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _ScreensaverSettings(),
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
                  Text(
                    s.t('media_folder'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    media.folderPath ?? s.t('media_folder_missing'),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    s.t('media_copy_hint'),
                    style: const TextStyle(
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
                            ? s.t('media_scanning')
                            : s.t('media_empty'),
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
                            it.kind == MediaKind.video
                                ? s.t('media_video')
                                : s.t('media_image'),
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

/// Timing controls for the attract loop, above the media list — the two
/// belong together: the operator uploads a clip and immediately wants to
/// say how long it gets on screen.
class _ScreensaverSettings extends StatelessWidget {
  const _ScreensaverSettings();

  String _fmt(BuildContext context, int sec) {
    final s = context.read<Strings>();
    if (sec < 60) return '$sec ${s.t('ss_sec')}';
    final m = sec ~/ 60;
    return '$m ${s.t('ss_min')}';
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final st = context.watch<DeviceStorage>();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.t('ss_settings'),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 10),
          _ChoiceRow(
            label: s.t('ss_delay'),
            values: DeviceStorage.screensaverDelayChoicesSec,
            selected: st.screensaverDelaySec,
            format: (v) => _fmt(context, v),
            onChanged: st.setScreensaverDelaySec,
          ),
          const SizedBox(height: 10),
          _ChoiceRow(
            label: s.t('ss_slide'),
            values: DeviceStorage.screensaverSlideChoicesSec,
            selected: st.screensaverSlideSec,
            format: (v) => _fmt(context, v),
            onChanged: st.setScreensaverSlideSec,
          ),
          const Divider(color: Colors.white24, height: 22),
          Row(
            children: [
              Switch(
                value: st.screensaverWaitVideoEnd,
                onChanged: st.setScreensaverWaitVideoEnd,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.t('ss_wait_video'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      s.t('ss_wait_video_hint'),
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12, height: 1.3),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Label plus a horizontally scrollable row of preset values. Presets, not
/// a free-text field: on a kiosk the operator has no keyboard half the time,
/// and a typo'd "300" seconds is a machine nobody can shop from.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.label,
    required this.values,
    required this.selected,
    required this.format,
    required this.onChanged,
  });

  final String label;
  final List<int> values;
  final int selected;
  final String Function(int) format;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final v in values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(format(v)),
                    selected: v == selected,
                    onSelected: (_) => onChanged(v),
                  ),
                ),
              // A value stored before these presets existed would otherwise
              // leave nothing selected and look like the setting is unset.
              if (!values.contains(selected))
                ChoiceChip(
                  label: Text(format(selected)),
                  selected: true,
                  onSelected: (_) {},
                ),
            ],
          ),
        ),
      ],
    );
  }
}
