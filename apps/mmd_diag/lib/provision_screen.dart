import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Field provisioning for a brand-new tablet, using nothing but this phone.
///
/// The technician's half of it is three taps and a camera; everything below is
/// the other half. Order is fixed and each step depends on the last, so the
/// screen is a checklist rather than a set of buttons — a half-provisioned
/// tablet is worse than an untouched one, because it looks finished.
///
/// The one step no software can take is the first: Wireless debugging has to
/// be switched on by hand on the tablet. Android wants proof that whoever is
/// provisioning the device is holding it, which is also what stops anyone on
/// the same Wi-Fi doing this to someone else's machine.
class ProvisionScreen extends StatefulWidget {
  const ProvisionScreen({super.key});

  @override
  State<ProvisionScreen> createState() => _ProvisionScreenState();
}

class _ProvisionScreenState extends State<ProvisionScreen> {
  static const _channel = MethodChannel('kz.smartvend/adb');
  static const _events = EventChannel('kz.smartvend/adb_events');

  /// Same artefact the tablets install from, so a machine provisioned in the
  /// field is on the same build as one provisioned at the bench.
  static const _apkUrl =
      'https://github.com/Samat1989/smartvend-tablet/releases/latest/download/app-armeabi-v7a-release.apk';
  static const _adminComponent =
      'kz.smartvend.m102_tester/kz.smartvend.m102_tester.KioskAdminReceiver';

  String? _qr;
  bool _connected = false;
  bool _busy = false;
  final _log = <String>[];

  @override
  void initState() {
    super.initState();
    _events.receiveBroadcastStream().listen((e) {
      if (e is! Map) return;
      final stage = e['stage']?.toString() ?? '';
      _say(e['message']?.toString() ?? '');
      if (stage == 'connected' && mounted) {
        // The QR has done its job; leaving it up invites a second scan that
        // would pair against a rendezvous nobody is listening on any more.
        setState(() {
          _connected = true;
          _qr = null;
        });
      }
    });
  }

  void _say(String line) {
    if (!mounted || line.isEmpty) return;
    setState(() => _log.insert(0, line));
  }

  Future<void> _startPairing() async {
    setState(() {
      _log.clear();
      _connected = false;
      _qr = null;
    });
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('startPairing');
      setState(() => _qr = res?['qr'] as String?);
    } on PlatformException catch (e) {
      _say('Ошибка: ${e.message}');
    }
  }

  /// Download, push, install, and only then hand over the rights.
  ///
  /// Owner comes last because `dpm set-device-owner` needs the admin receiver
  /// to already exist on the device — and because a tablet that got the app
  /// but not the rights can be finished later, while the reverse cannot.
  Future<void> _installAndOwn() async {
    setState(() => _busy = true);
    try {
      _say('Скачиваю приложение…');
      final res = await http.get(Uri.parse(_apkUrl));
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}');
      }
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/kiosk.apk');
      await file.writeAsBytes(res.bodyBytes);
      _say('Скачано ${(res.bodyBytes.length / 1048576).toStringAsFixed(1)} МБ');

      await _channel.invokeMethod('installApk', {'path': file.path});
      await _channel.invokeMethod(
        'setDeviceOwner',
        {'component': _adminComponent},
      );
      _say('Планшет готов. Перезагрузите его.');
    } on PlatformException catch (e) {
      _say('Ошибка: ${e.message}');
    } catch (e) {
      _say('Ошибка: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Настройка планшета')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _Step(
            n: 1,
            title: 'На планшете',
            body: 'Настройки → О планшете → 7 раз по «Номер сборки».\n'
                'Затем Для разработчиков → Беспроводная отладка → включить.\n\n'
                'Аккаунт Google добавлять нельзя — с ним права не выдать.',
          ),
          const _Step(
            n: 2,
            title: 'Телефон и планшет — в одной сети',
            body: 'Проще всего раздать интернет с телефона и подключить '
                'планшет к нему.',
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _startPairing,
            icon: const Icon(Icons.qr_code_2),
            label: const Text('Показать QR для сопряжения'),
          ),
          if (_qr != null) ...[
            const SizedBox(height: 16),
            const _Step(
              n: 3,
              title: 'Сканируйте с планшета',
              body: 'Беспроводная отладка → Подключить с помощью QR-кода. '
                  'Камера планшета читает этот код.',
            ),
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                color: Colors.white,
                child: QrImageView(data: _qr!, size: 240),
              ),
            ),
          ],
          if (_connected) ...[
            const SizedBox(height: 16),
            const _Step(
              n: 4,
              title: 'Планшет подключён',
              body: 'Приложение будет скачано, установлено, и ему выдадутся '
                  'права администратора.',
            ),
            FilledButton.icon(
              onPressed: _busy ? null : _installAndOwn,
              icon: const Icon(Icons.download_done),
              label: const Text('Установить и выдать права'),
            ),
          ],
          if (_busy) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
          if (_log.isNotEmpty) ...[
            const SizedBox(height: 24),
            const Text('Журнал', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            for (final line in _log)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  line,
                  style: TextStyle(
                    fontSize: 13,
                    color: line.startsWith('Ошибка')
                        ? Colors.red.shade700
                        : Colors.black87,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.title, required this.body});

  final int n;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(radius: 14, child: Text('$n')),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(body, style: const TextStyle(height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
