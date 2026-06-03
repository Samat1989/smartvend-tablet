import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/device_storage.dart';
import '../services/strings.dart';
import '../services/supabase_api.dart';
import '../theme.dart';

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _machidCtrl = TextEditingController();
  final _secretCtrl = TextEditingController();
  final _api = SupabaseApi();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _machidCtrl.dispose();
    _secretCtrl.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final machid = _machidCtrl.text.trim();
    final secret = _secretCtrl.text.trim();
    if (machid.isEmpty || secret.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await _api.verifyPairing(machid, secret);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    await context.read<DeviceStorage>().savePairing(machid: machid, secret: secret);
    // main.dart watches DeviceStorage and will swap to HomeScreen automatically.
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: const [appCardShadow],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const _LangSwitcher(),
                      const SizedBox(height: 8),
                      Container(
                        width: 88,
                        height: 88,
                        decoration: const BoxDecoration(
                          gradient: signatureGradient,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.point_of_sale,
                            size: 44, color: Colors.white),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        s.t('pairing_title').toUpperCase(),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.5,
                            color: AppColors.onSurface),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        s.t('pairing_subtitle'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.onSurfaceVariant,
                            height: 1.4),
                      ),
                      const SizedBox(height: 28),
                      TextField(
                        controller: _machidCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: InputDecoration(
                          labelText: s.t('machid_label'),
                          prefixIcon: const Icon(Icons.numbers,
                              color: AppColors.onSurfaceVariant),
                          fillColor: AppColors.surfaceContainerLow,
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _secretCtrl,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: s.t('secret_label'),
                          prefixIcon: const Icon(Icons.key,
                              color: AppColors.onSurfaceVariant),
                          fillColor: AppColors.surfaceContainerLow,
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0x1AB3261E),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.error_outline,
                                  color: Color(0xFFB3261E), size: 20),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _error!,
                                  style: const TextStyle(
                                      color: Color(0xFFB3261E),
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Container(
                        decoration: BoxDecoration(
                          gradient: signatureGradient,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x339C3F00),
                              blurRadius: 16,
                              offset: Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Material(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(16),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: _busy ? null : _connect,
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 18),
                              child: _busy
                                  ? Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white),
                                        ),
                                        const SizedBox(width: 12),
                                        Text(
                                          s.t('verifying'),
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 14,
                                              letterSpacing: 0.5),
                                        ),
                                      ],
                                    )
                                  : Text(
                                      s.t('connect_btn').toUpperCase(),
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: 1.2,
                                          color: Colors.white),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LangSwitcher extends StatelessWidget {
  const _LangSwitcher();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    return Align(
      alignment: Alignment.topRight,
      child: SegmentedButton<String>(
        showSelectedIcon: false,
        style: SegmentedButton.styleFrom(
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        ),
        segments: const [
          ButtonSegment(value: 'ru', label: Text('RU')),
          ButtonSegment(value: 'kk', label: Text('KZ')),
          ButtonSegment(value: 'en', label: Text('EN')),
        ],
        selected: {s.lang},
        onSelectionChanged: (set) => s.setLang(set.first),
      ),
    );
  }
}
