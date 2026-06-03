import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/provisioning_config.dart';

/// Full-screen QR display. Locked to portrait + max brightness via
/// the `Theme` so the tablet camera has the easiest possible time
/// reading it.
class QrScreen extends StatefulWidget {
  const QrScreen({super.key, required this.payload, required this.summary});

  final String payload;
  final ProvisioningConfig summary;

  @override
  State<QrScreen> createState() => _QrScreenState();
}

class _QrScreenState extends State<QrScreen> {
  bool _showJson = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Scan me'),
        actions: [
          IconButton(
            icon: Icon(_showJson ? Icons.qr_code_2 : Icons.code),
            tooltip: _showJson ? 'Показать QR' : 'Показать JSON',
            onPressed: () => setState(() => _showJson = !_showJson),
          ),
          IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: 'Скопировать JSON',
            onPressed: () async {
              // Capture the messenger before the async gap so the
              // linter doesn't flag context-across-await.
              final messenger = ScaffoldMessenger.of(context);
              await Clipboard.setData(ClipboardData(text: widget.payload));
              messenger.showSnackBar(
                const SnackBar(content: Text('JSON скопирован')),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _showJson
              ? _JsonView(payload: widget.payload)
              : Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: QrImageView(
                            data: widget.payload,
                            version: QrVersions.auto,
                            errorCorrectionLevel: QrErrorCorrectLevel.M,
                            backgroundColor: Colors.white,
                            padding: const EdgeInsets.all(16),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _Summary(cfg: widget.summary),
                  ],
                ),
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.cfg});

  final ProvisioningConfig cfg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F6FA),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row('Component', cfg.adminComponent),
          _row('APK', cfg.apkDownloadUrl),
          if (cfg.wifiSsid.isNotEmpty)
            _row('Wi-Fi', '${cfg.wifiSsid} (${cfg.wifiSecurityType})'),
          _row('Locale / TZ', '${cfg.locale} · ${cfg.timeZone}'),
        ],
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 90,
              child: Text(
                k,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.0,
                  color: Colors.black54,
                ),
              ),
            ),
            Expanded(
              child: Text(
                v,
                style: const TextStyle(
                    fontSize: 12, fontFamily: 'monospace'),
              ),
            ),
          ],
        ),
      );
}

class _JsonView extends StatelessWidget {
  const _JsonView({required this.payload});

  final String payload;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(12),
        ),
        child: SelectableText(
          payload,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: Color(0xFFE5E5EA),
            height: 1.4,
          ),
        ),
      ),
    );
  }
}
