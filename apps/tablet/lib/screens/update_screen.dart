import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/update_service.dart';

/// Service-mode update tile destination.
///
/// Shows the currently-installed version, a "Check" button that hits
/// the GitHub API, and a confirmation step with the release notes
/// before downloading + installing.
class UpdateScreen extends StatefulWidget {
  const UpdateScreen({super.key});

  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  final _service = UpdateService(
    owner: 'Samat1989',
    repo: 'smartvend-tablet',
  );

  PackageInfo? _info;
  bool _checking = false;
  bool _downloading = false;
  String? _error;
  UpdateInfo? _update;
  int _received = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((i) {
      if (mounted) setState(() => _info = i);
    });
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
      _update = null;
    });
    try {
      final info = await _service.check();
      if (!mounted) return;
      setState(() {
        _checking = false;
        if (info == null) {
          // No release with the right asset.
          _error = 'Релизов с APK не найдено';
        } else if (!info.isNewer) {
          _update = info; // shown as "up-to-date"
        } else {
          _update = info;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _downloadAndInstall() async {
    final info = _update;
    if (info == null) return;
    setState(() {
      _downloading = true;
      _received = 0;
      _total = info.assetSize;
      _error = null;
    });
    try {
      await _service.downloadAndInstall(
        info,
        onProgress: (rec, tot) {
          if (!mounted) return;
          setState(() {
            _received = rec;
            _total = tot;
          });
        },
      );
      // PackageInstaller will kill + relaunch us on success. If we're
      // still here a few seconds later something failed.
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Обновление')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _versionCard(),
          const SizedBox(height: 16),
          if (_error != null) _errorCard(),
          if (_update != null) _updateCard(),
          if (_downloading) _progressCard(),
          if (_update == null && !_checking) _checkButton(),
        ],
      ),
    );
  }

  Widget _versionCard() {
    final info = _info;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.smartphone, color: Colors.indigo),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Текущая версия',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.0,
                      color: Colors.black54,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    info == null
                        ? '…'
                        : '${info.version}  ·  build ${info.buildNumber}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (info != null)
                    Text(
                      info.packageName,
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.black45,
                        fontFamily: 'monospace',
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _checkButton() {
    return FilledButton.icon(
      icon: _checking
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.cloud_sync),
      label: Text(_checking ? 'Проверяем…' : 'Проверить обновление'),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
      ),
      onPressed: _checking ? null : _check,
    );
  }

  Widget _updateCard() {
    final info = _update!;
    final isNewer = info.isNewer;
    return Card(
      color: isNewer ? Colors.green.shade50 : Colors.grey.shade100,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isNewer ? Icons.system_update : Icons.check_circle,
                  color: isNewer ? Colors.green.shade700 : Colors.black54,
                ),
                const SizedBox(width: 8),
                Text(
                  isNewer ? 'Доступна новая версия' : 'У вас актуальная версия',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: isNewer ? Colors.green.shade900 : Colors.black87,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '${info.versionName}  (build ${info.versionCode})',
              style: const TextStyle(
                  fontSize: 20, fontWeight: FontWeight.w900),
            ),
            Text(
              'Размер: ${info.assetSizeHuman}  ·  тег ${info.tagName}',
              style: const TextStyle(
                  fontSize: 12, color: Colors.black54),
            ),
            if (info.body.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text(
                'Изменения',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                    color: Colors.black54),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.black12),
                ),
                constraints: const BoxConstraints(maxHeight: 200),
                child: SingleChildScrollView(
                  child: Text(info.body,
                      style: const TextStyle(fontSize: 12)),
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (isNewer)
              FilledButton.icon(
                icon: const Icon(Icons.download),
                label: const Text('Скачать и установить'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                onPressed: _downloading ? null : _downloadAndInstall,
              )
            else
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Проверить ещё раз'),
                onPressed: () {
                  setState(() => _update = null);
                  _check();
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _progressCard() {
    final pct = _total > 0 ? (_received / _total) : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Загрузка…',
                style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: pct),
            const SizedBox(height: 6),
            Text(
              _total > 0
                  ? '${(_received / 1024 / 1024).toStringAsFixed(1)} / '
                      '${(_total / 1024 / 1024).toStringAsFixed(1)} МБ'
                  : '${(_received / 1024 / 1024).toStringAsFixed(1)} МБ',
              style: const TextStyle(fontSize: 11, color: Colors.black54),
            ),
            const SizedBox(height: 6),
            const Text(
              'Не выключайте планшет — приложение перезапустится автоматически.',
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorCard() {
    return Card(
      color: Colors.red.shade50,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: Colors.red.shade700),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _error!,
                style: TextStyle(color: Colors.red.shade900, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
