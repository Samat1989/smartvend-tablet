import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/provisioning_config.dart';
import '../services/checksum_helper.dart';
import '../services/config_storage.dart';
import 'qr_screen.dart';

/// Single-screen form: operator pastes APK URL + cert SHA-256 +
/// Wi-Fi creds and taps "Показать QR".
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.storage});

  final ConfigStorage storage;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late ProvisioningConfig _cfg;
  late TextEditingController _apkCtrl;
  late TextEditingController _hashCtrl;
  late TextEditingController _ssidCtrl;
  late TextEditingController _pwdCtrl;
  late TextEditingController _localeCtrl;
  late TextEditingController _tzCtrl;

  String? _hashError;

  @override
  void initState() {
    super.initState();
    _cfg = widget.storage.load();
    _apkCtrl = TextEditingController(text: _cfg.apkDownloadUrl);
    _hashCtrl = TextEditingController(text: _cfg.signatureChecksumBase64);
    _ssidCtrl = TextEditingController(text: _cfg.wifiSsid);
    _pwdCtrl = TextEditingController(text: _cfg.wifiPassword);
    _localeCtrl = TextEditingController(text: _cfg.locale);
    _tzCtrl = TextEditingController(text: _cfg.timeZone);
  }

  @override
  void dispose() {
    _apkCtrl.dispose();
    _hashCtrl.dispose();
    _ssidCtrl.dispose();
    _pwdCtrl.dispose();
    _localeCtrl.dispose();
    _tzCtrl.dispose();
    super.dispose();
  }

  void _persist() {
    _cfg = _cfg.copyWith(
      apkDownloadUrl: _apkCtrl.text.trim(),
      signatureChecksumBase64: _hashCtrl.text.trim(),
      wifiSsid: _ssidCtrl.text.trim(),
      wifiPassword: _pwdCtrl.text,
      locale: _localeCtrl.text.trim(),
      timeZone: _tzCtrl.text.trim(),
    );
    widget.storage.save(_cfg);
  }

  /// Operator can paste keystool's colon-hex output ("9E:C3:CC:..."); convert
  /// it to base64-url-safe in place. Idempotent — if the field already
  /// holds a valid base64 string we leave it alone.
  void _convertHexIfNeeded() {
    final v = _hashCtrl.text.trim();
    if (v.contains(':')) {
      final converted = ChecksumHelper.keytoolHexToBase64UrlSafe(v);
      if (converted != null) {
        _hashCtrl.text = converted;
        setState(() => _hashError = null);
      } else {
        setState(() => _hashError = 'Не похоже на keytool SHA-256');
      }
    } else if (v.isNotEmpty &&
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(v)) {
      setState(() => _hashError = 'Хэш должен быть base64 URL-safe');
    } else {
      setState(() => _hashError = null);
    }
  }

  Future<void> _showQr() async {
    _convertHexIfNeeded();
    _persist();
    if (!_cfg.isReady) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Заполните URL APK и SHA-256 ключа подписи'),
        backgroundColor: Colors.redAccent,
      ));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => QrScreen(payload: _cfg.toQrString(), summary: _cfg),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Smartvend Provision QR'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: 'Как пользоваться',
            onPressed: _showHelp,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Section(
            title: 'APK',
            child: Column(
              children: [
                TextFormField(
                  controller: _apkCtrl,
                  decoration: const InputDecoration(
                    labelText: 'URL .apk',
                    hintText: 'https://github.com/.../app-armeabi-v7a-release.apk',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => _persist(),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _hashCtrl,
                  decoration: InputDecoration(
                    labelText: 'SHA-256 ключа подписи',
                    hintText:
                        'AB:CD:… (из keytool) или base64 URL-safe',
                    border: const OutlineInputBorder(),
                    errorText: _hashError,
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.transform),
                      tooltip: 'Конвертировать hex → base64',
                      onPressed: () {
                        _convertHexIfNeeded();
                        _persist();
                      },
                    ),
                  ),
                  onChanged: (_) {
                    _persist();
                    setState(() => _hashError = null);
                  },
                  onEditingComplete: _convertHexIfNeeded,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 13),
                  maxLines: 2,
                ),
                const SizedBox(height: 6),
                const _HintText(
                  '`keytool -list -keystore release.jks -alias smartvend` → '
                  'строка SHA-256 (вкл. двоеточия). Кнопка справа сконвертит.',
                ),
              ],
            ),
          ),
          _Section(
            title: 'Wi-Fi (опционально)',
            child: Column(
              children: [
                TextFormField(
                  controller: _ssidCtrl,
                  decoration: const InputDecoration(
                    labelText: 'SSID',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => _persist(),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _pwdCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Пароль',
                    border: OutlineInputBorder(),
                  ),
                  obscureText: true,
                  onChanged: (_) => _persist(),
                ),
                const SizedBox(height: 12),
                _SecurityPicker(
                  selected: _cfg.wifiSecurityType,
                  onChanged: (s) {
                    setState(() {
                      _cfg = _cfg.copyWith(wifiSecurityType: s);
                    });
                    _persist();
                  },
                ),
                const SizedBox(height: 6),
                const _HintText(
                  'Если оставить пустым, планшет на первом запуске спросит сеть сам.',
                ),
              ],
            ),
          ),
          _Section(
            title: 'Региональные настройки',
            child: Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _localeCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Locale',
                      hintText: 'ru_RU',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => _persist(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _tzCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Time zone',
                      hintText: 'Asia/Almaty',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => _persist(),
                  ),
                ),
              ],
            ),
          ),
          _Section(
            title: 'Доп. опции',
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Пропустить шифрование'),
                  subtitle: const Text(
                    'Рекомендуется для kiosk — без шифрования диск пишется быстрее, нет boot-пароля.',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: _cfg.skipEncryption,
                  onChanged: (v) {
                    setState(() {
                      _cfg = _cfg.copyWith(skipEncryption: v);
                    });
                    _persist();
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Оставить системные приложения'),
                  subtitle: const Text(
                    'Camera, Settings — нужны для редких сервисных операций.',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: _cfg.leaveAllSystemAppsEnabled,
                  onChanged: (v) {
                    setState(() {
                      _cfg = _cfg.copyWith(leaveAllSystemAppsEnabled: v);
                    });
                    _persist();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.qr_code_2),
            label: const Text('Показать QR',
                style: TextStyle(fontWeight: FontWeight.bold)),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 18),
            ),
            onPressed: _showQr,
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            icon: const Icon(Icons.copy_all_outlined),
            label: const Text('Скопировать JSON'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: () async {
              _convertHexIfNeeded();
              _persist();
              final messenger = ScaffoldMessenger.of(context);
              await Clipboard.setData(
                ClipboardData(text: _cfg.toQrString()),
              );
              messenger.showSnackBar(
                const SnackBar(content: Text('JSON скопирован')),
              );
            },
          ),
        ],
      ),
    );
  }

  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Как пользоваться'),
        content: const SingleChildScrollView(
          child: Text(
            'На свежем (после factory reset) планшете на экране '
            'Welcome тапните 6 раз в любом месте — откроется камера '
            'для сканирования QR provisioning-кода.\n\n'
            'Покажите ему QR с этого экрана. Android сам:\n'
            '• подключится к Wi-Fi (если указали)\n'
            '• скачает APK с указанного URL\n'
            '• проверит SHA-256 сертификата\n'
            '• установит приложение как device-owner\n'
            '• завершит setup wizard\n\n'
            'Время операции — около 1 минуты.',
            style: TextStyle(height: 1.5),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 10, left: 4),
            child: Text(
              title.toUpperCase(),
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
                color: Colors.black54,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.black12),
            ),
            child: child,
          ),
        ],
      ),
    );
  }
}

class _HintText extends StatelessWidget {
  const _HintText(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: const TextStyle(fontSize: 11, color: Colors.black54),
      ),
    );
  }
}

class _SecurityPicker extends StatelessWidget {
  const _SecurityPicker({required this.selected, required this.onChanged});

  final String selected;
  final ValueChanged<String> onChanged;

  static const _options = ['WPA', 'WEP', 'EAP', 'NONE'];

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<String>(
      segments: [
        for (final o in _options)
          ButtonSegment(value: o, label: Text(o)),
      ],
      selected: {selected},
      onSelectionChanged: (set) => onChanged(set.first),
      showSelectedIcon: false,
    );
  }
}
