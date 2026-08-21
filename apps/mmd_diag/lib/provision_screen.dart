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
  bool _manual = false;
  final _log = <String>[];
  final _hostPort = TextEditingController();
  final _debugHostPort = TextEditingController();
  final _code = TextEditingController();

  @override
  void initState() {
    super.initState();
    _events.receiveBroadcastStream().listen((e) {
      if (e is! Map) return;
      final stage = e['stage']?.toString() ?? '';
      _say(e['message']?.toString() ?? '');
      if (stage == 'needPairing' && mounted) {
        // Only now is the QR worth showing: reconnecting failed, so the
        // tablet either never knew us or has forgotten.
        _startPairing();
        return;
      }
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

  @override
  void dispose() {
    _hostPort.dispose();
    _debugHostPort.dispose();
    _code.dispose();
    super.dispose();
  }

  /// Pair from what the tablet prints, when discovery has come up empty.
  ///
  /// The QR route needs mDNS, and mDNS has to survive multicast filtering,
  /// OEM power management and whatever the shop router does to broadcast
  /// traffic. The tablet's own "Pair device with pairing code" screen shows
  /// an address and six digits, and this path needs nothing else.
  Future<void> _pairManual() async {
    final raw = _hostPort.text.trim();
    final at = raw.lastIndexOf(':');
    if (at < 1) {
      _say('Ошибка: адрес нужен в виде 192.168.1.50:41234');
      return;
    }
    final port = int.tryParse(raw.substring(at + 1));
    if (port == null) {
      _say('Ошибка: порт не разобран');
      return;
    }
    try {
      await _channel.invokeMethod('pairManual', {
        'host': raw.substring(0, at),
        'port': port,
        'code': _code.text.trim(),
      });
    } on PlatformException catch (e) {
      _say('Ошибка: ${e.message}');
    }
  }

  /// Connect to an address read off the tablet's own screen.
  ///
  /// Every automatic route to the debugging port goes through mDNS, and mDNS
  /// is at the mercy of the network: on one Wi-Fi the tablet's
  /// `_adb-tls-connect._tcp` record arrives in seconds, on another it never
  /// arrives at all while the pairing record from the same tablet does. The
  /// Wireless debugging screen prints the address and port in plain text, so
  /// this path needs no discovery, no multicast and no cooperation from the
  /// router.
  Future<void> _connectDirect() async {
    final raw = _debugHostPort.text.trim();
    final at = raw.lastIndexOf(':');
    final port = at < 1 ? null : int.tryParse(raw.substring(at + 1));
    if (port == null) {
      _say('Ошибка: нужен адрес вида 192.168.1.50:37021');
      return;
    }
    try {
      await _channel.invokeMethod('connectDirect', {
        'host': raw.substring(0, at),
        'port': port,
      });
    } on PlatformException catch (e) {
      _say('Ошибка: ${e.message}');
    }
  }

  void _say(String line) {
    if (!mounted || line.isEmpty) return;
    setState(() => _log.insert(0, line));
  }

  /// Try the connection we may already have before asking for a new one.
  ///
  /// The phone's ADB identity is generated once and kept, and the tablet
  /// remembers it — so a tablet paired last week needs no QR, only for
  /// wireless debugging to be switched on again, which no reboot survives.
  /// Starting from the QR every time asked the technician to redo work the
  /// tablet had not forgotten, and quietly filled its paired-devices list.
  Future<void> _reconnect() async {
    setState(() {
      _log.clear();
      _connected = false;
      _qr = null;
    });
    try {
      await _channel.invokeMethod('reconnect');
    } on PlatformException catch (e) {
      _say('Ошибка: ${e.message}');
    }
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

      // Read the policy back instead of trusting our own command: dpm
      // printing Success is weaker evidence than the tablet naming the
      // owner itself.
      final verdict = await _channel.invokeMethod<String>('verifyOwner');
      if (verdict != 'ok') {
        _say('Ошибка: права не подтвердились — $verdict');
        return;
      }
      _say('Права подтверждены планшетом');

      // The kiosk reads its policy once, in onCreate. It was already running
      // when the rights arrived, so until it starts again it behaves exactly
      // like an unprovisioned tablet — which is what makes a technician
      // think nothing happened.
      await _channel.invokeMethod('reboot');
      _say('Готово. Планшет перезагружается сам, ждать не нужно.');
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
            title: 'Телефон и планшет — в одной сети Wi-Fi',
            body: 'Обычная сеть, к которой подключены оба. Раздача с '
                'телефона тоже иногда работает, но поиск планшета по ней '
                'ненадёжен — если не найдёт, внизу есть подключение по '
                'адресу вручную.',
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _reconnect,
            icon: const Icon(Icons.link),
            label: const Text('Подключить планшет'),
          ),
          TextButton.icon(
            onPressed: _busy ? null : _startPairing,
            icon: const Icon(Icons.qr_code_2),
            label: const Text('Сопрячь заново по QR'),
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
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => setState(() => _manual = !_manual),
            icon: Icon(_manual ? Icons.expand_less : Icons.expand_more),
            label: const Text('Не находит? Ввести код вручную'),
          ),
          if (_manual) ...[
            const _Step(
              n: 3,
              title: 'Ручное сопряжение',
              body: 'На планшете: Беспроводная отладка → Подключить с '
                  'помощью кода сопряжения. Перепишите адрес с портом и '
                  'шесть цифр.',
            ),
            TextField(
              controller: _hostPort,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Адрес и порт',
                hintText: '192.168.1.50:41234',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Код сопряжения',
                hintText: '123456',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _pairManual,
              icon: const Icon(Icons.link),
              label: const Text('Сопрячь по коду'),
            ),
            const Divider(height: 32),
            const _Step(
              n: 4,
              title: 'Подключение по адресу',
              body: 'Если сопряжение прошло, но подключиться не удаётся — '
                  'возьмите «IP-адрес и порт» с самого верха экрана '
                  'Беспроводной отладки. Порт там другой, не тот, что был '
                  'у кода сопряжения.',
            ),
            TextField(
              controller: _debugHostPort,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Адрес и порт отладки',
                hintText: '192.168.1.50:37021',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _connectDirect,
              icon: const Icon(Icons.cable),
              label: const Text('Подключиться по адресу'),
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
