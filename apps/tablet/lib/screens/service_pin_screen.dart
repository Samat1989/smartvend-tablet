import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/device_storage.dart';
import '../services/strings.dart';
import 'service_menu_screen.dart';

/// Service-mode gate. Three states:
///   • locked   — too many wrong attempts; show a countdown, no input
///   • create   — no PIN set yet (fresh machine, or migrated off the old
///                default '1234'); operator must create one (+ confirm)
///   • enter    — normal PIN entry, limited to [DeviceStorage.maxPinAttempts]
class ServicePinScreen extends StatefulWidget {
  const ServicePinScreen({super.key});

  @override
  State<ServicePinScreen> createState() => _ServicePinScreenState();
}

class _ServicePinScreenState extends State<ServicePinScreen> {
  final _ctrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _goToMenu() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const ServiceMenuScreen()),
    );
  }

  Future<void> _onCreate() async {
    final pin = _ctrl.text.trim();
    final reason = DeviceStorage.validatePin(pin);
    if (reason != null) {
      setState(() => _error = reason);
      return;
    }
    if (pin != _confirmCtrl.text.trim()) {
      setState(() => _error = 'PIN не совпадает');
      return;
    }
    await context.read<DeviceStorage>().setServicePin(pin);
    if (!mounted) return;
    _goToMenu();
  }

  Future<void> _onEnter() async {
    final storage = context.read<DeviceStorage>();
    if (storage.isPinLocked) return;
    final entered = _ctrl.text.trim();
    if (storage.verifyServicePin(entered)) {
      await storage.resetPinAttempts();
      if (!mounted) return;
      _goToMenu();
      return;
    }
    final lockedNow = await storage.registerPinFailure();
    if (!mounted) return;
    _ctrl.clear();
    setState(() {
      _error = lockedNow
          ? null
          : 'Неверный PIN. Осталось попыток: ${storage.pinAttemptsRemaining}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final storage = context.watch<DeviceStorage>();

    final Widget body;
    if (storage.isPinLocked) {
      body = _lockedBody(storage);
    } else if (!storage.servicePinIsSet) {
      body = _createBody();
    } else {
      body = _enterBody(s);
    }

    return Scaffold(
      backgroundColor: Colors.grey.shade900,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(s.t('service_mode'),
            style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: body,
          ),
        ),
      ),
    );
  }

  Widget _icon(IconData icon, Color color) => Container(
        width: 80,
        height: 80,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.2),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 36, color: color),
      );

  InputDecoration _pinDecoration({String? errorText}) => InputDecoration(
        counterText: '',
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.08),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        errorText: errorText,
      );

  TextStyle get _pinTextStyle => const TextStyle(
      color: Colors.white,
      fontSize: 28,
      letterSpacing: 8,
      fontWeight: FontWeight.bold);

  List<TextInputFormatter> get _digits =>
      [FilteringTextInputFormatter.digitsOnly];

  // ── locked ──────────────────────────────────────────────────────
  Widget _lockedBody(DeviceStorage storage) {
    final until = storage.pinLockedUntil;
    final mins = until == null
        ? 0
        : (until.difference(DateTime.now()).inSeconds / 60).ceil();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _icon(Icons.lock_clock, Colors.redAccent),
        const SizedBox(height: 16),
        const Text(
          'Слишком много попыток',
          style: TextStyle(
              color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          'Ввод PIN заблокирован. Попробуйте через ~$mins мин.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
        ),
      ],
    );
  }

  // ── create ──────────────────────────────────────────────────────
  Widget _createBody() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _icon(Icons.lock_reset, Colors.amber.shade400),
        const SizedBox(height: 16),
        const Text(
          'Задайте сервис-PIN',
          style: TextStyle(
              color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          'PIN по умолчанию больше не используется. Придумайте свой '
          '(минимум ${DeviceStorage.minPinLength} цифры).',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _ctrl,
          obscureText: true,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 8,
          textAlign: TextAlign.center,
          inputFormatters: _digits,
          style: _pinTextStyle,
          decoration: _pinDecoration(),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _confirmCtrl,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 8,
          textAlign: TextAlign.center,
          inputFormatters: _digits,
          style: _pinTextStyle,
          decoration: _pinDecoration(errorText: _error).copyWith(
            hintText: 'Повторите PIN',
            hintStyle: TextStyle(color: Colors.grey.shade600, letterSpacing: 0),
          ),
          onSubmitted: (_) => _onCreate(),
        ),
        const SizedBox(height: 16),
        FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            backgroundColor: Colors.amber.shade700,
          ),
          onPressed: _onCreate,
          child: const Text('Сохранить PIN',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }

  // ── enter ───────────────────────────────────────────────────────
  Widget _enterBody(Strings s) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _icon(Icons.lock_outline, Colors.amber.shade400),
        const SizedBox(height: 16),
        Text(
          s.t('enter_pin'),
          style: const TextStyle(
              color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _ctrl,
          obscureText: true,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 8,
          textAlign: TextAlign.center,
          inputFormatters: _digits,
          style: _pinTextStyle,
          decoration: _pinDecoration(errorText: _error),
          onSubmitted: (_) => _onEnter(),
        ),
        const SizedBox(height: 16),
        FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            backgroundColor: Colors.amber.shade700,
          ),
          onPressed: _onEnter,
          child: Text(s.t('connect_btn'),
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}
