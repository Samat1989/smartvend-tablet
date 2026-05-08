import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/device_storage.dart';
import '../services/payment_service.dart';
import '../services/strings.dart';
import '../services/vending_service.dart';
import '../theme.dart';
import 'dispense_screen.dart';

enum _State { creating, waiting, success, failed, expired }

class PaymentScreen extends StatefulWidget {
  const PaymentScreen({super.key});

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  final _service = PaymentService();
  PaymentRequest? _request;
  _State _state = _State.creating;
  String _statusMsg = '';
  String? _statusDetails;
  Timer? _pollTimer;
  Timer? _overallTimer;
  DateTime? _startedAt;

  static const _pollInterval = Duration(seconds: 3);
  static const _overallTimeout = Duration(minutes: 5);

  @override
  void initState() {
    super.initState();
    _startFlow();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _overallTimer?.cancel();
    super.dispose();
  }

  Future<void> _startFlow() async {
    setState(() {
      _state = _State.creating;
      _statusMsg = '';
      _statusDetails = null;
    });
    final storage = context.read<DeviceStorage>();
    final vending = context.read<VendingService>();
    final machid = storage.machid;
    final secret = storage.secret;
    if (machid == null || secret == null) {
      setState(() {
        _state = _State.failed;
        _statusMsg = 'Аппарат не настроен';
      });
      return;
    }
    final total = vending.cartTotalTenge;
    final names = vending.cartItems.map((i) => i.product.name).join(', ');
    try {
      final req = await _service.createPayment(
        machid: machid,
        secret: secret,
        priceTenge: total,
        name: names.isEmpty ? 'Order' : names,
      );
      if (!mounted) return;
      _request = req;
      _startedAt = DateTime.now();
      setState(() => _state = _State.waiting);
      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _State.failed;
        _statusMsg = e.toString();
        _statusDetails = e is PaymentException ? e.details : null;
      });
    }
  }

  void _startPolling() {
    final storage = context.read<DeviceStorage>();
    final machid = storage.machid!;
    final secret = storage.secret!;
    final req = _request!;

    _pollTimer = Timer.periodic(_pollInterval, (_) async {
      if (!mounted) return;
      final status = await _service.pollResult(
        machid: machid,
        secret: secret,
        orderid: req.orderid,
        torderid: req.torderid,
      );
      if (!mounted) return;
      switch (status) {
        case PaymentStatus.success:
        case PaymentStatus.completed:
          _stopTimers();
          setState(() => _state = _State.success);
          await Future.delayed(const Duration(milliseconds: 800));
          if (!mounted) return;
          // Persist payment id so dispense screen can record sale.
          context.read<VendingService>().beginPaidDispense(
                paymentId: req.torderid.isNotEmpty ? req.torderid : req.orderid,
              );
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const DispenseScreen()),
          );
          break;
        case PaymentStatus.expired:
          _stopTimers();
          setState(() {
            _state = _State.expired;
            _statusMsg = 'Время оплаты истекло';
          });
          break;
        case PaymentStatus.closed:
          _stopTimers();
          setState(() {
            _state = _State.failed;
            _statusMsg = 'Транзакция закрыта';
          });
          break;
        case PaymentStatus.waiting:
        case PaymentStatus.unknown:
          break;
      }
    });

    _overallTimer = Timer(_overallTimeout, () {
      if (!mounted) return;
      _stopTimers();
      setState(() {
        _state = _State.expired;
        _statusMsg = 'Время оплаты истекло';
      });
    });
  }

  void _stopTimers() {
    _pollTimer?.cancel();
    _overallTimer?.cancel();
    _pollTimer = null;
    _overallTimer = null;
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final svc = context.watch<VendingService>();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(s.t('payment_title').toUpperCase(),
            style: const TextStyle(
                fontWeight: FontWeight.w900,
                letterSpacing: -0.5,
                fontSize: 22)),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              children: [
                _amountCard(s, svc.cartTotalTenge),
                const SizedBox(height: 16),
                _bodyCard(s),
                const SizedBox(height: 16),
                _bottomActions(s),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _amountCard(Strings s, int total) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [appCardShadow],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            s.t('cart_total').toUpperCase(),
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
                color: AppColors.onSurfaceVariant),
          ),
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: '$total ',
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w900,
                    color: AppColors.primary,
                    letterSpacing: -1,
                  ),
                ),
                const TextSpan(
                  text: '₸',
                  style: TextStyle(
                    fontSize: 16,
                    color: Color(0x809C3F00),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bodyCard(Strings s) {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [appCardShadow],
      ),
      child: switch (_state) {
        _State.creating => _busyView(s.t('verifying')),
        _State.waiting => _qrView(s),
        _State.success => _successView(s),
        _State.failed => _failedView(s),
        _State.expired => _failedView(s, expired: true),
      },
    );
  }

  Widget _busyView(String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 32),
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(label, style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _qrView(Strings s) {
    final code = _request?.twocode ?? '';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(20),
          ),
          child: QrImageView(
            data: code,
            size: 260,
            backgroundColor: AppColors.surfaceContainerLow,
            eyeStyle: const QrEyeStyle(
              eyeShape: QrEyeShape.square,
              color: AppColors.onSurface,
            ),
            dataModuleStyle: const QrDataModuleStyle(
              dataModuleShape: QrDataModuleShape.square,
              color: AppColors.onSurface,
            ),
            errorCorrectionLevel: QrErrorCorrectLevel.M,
          ),
        ),
        const SizedBox(height: 24),
        Text(
          s.t('scan_qr_kaspi'),
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.primary),
            ),
            const SizedBox(width: 10),
            Text(s.t('waiting_payment'),
                style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.onSurfaceVariant,
                    fontWeight: FontWeight.w600)),
          ],
        ),
        if (_startedAt != null) ...[
          const SizedBox(height: 6),
          Text(
            _remainingLabel(),
            style: const TextStyle(
                fontSize: 11,
                color: AppColors.onSurfaceVariant,
                fontFeatures: [FontFeature.tabularFigures()]),
          ),
        ],
      ],
    );
  }

  String _remainingLabel() {
    final elapsed = DateTime.now().difference(_startedAt!);
    final left = _overallTimeout - elapsed;
    if (left.isNegative) return '';
    final m = left.inMinutes;
    final s = left.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Widget _successView(Strings s) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 16),
        Container(
          width: 110,
          height: 110,
          decoration: const BoxDecoration(
            color: Color(0x1A9C3F00),
            shape: BoxShape.circle,
          ),
          child:
              const Icon(Icons.check_circle, size: 64, color: AppColors.primary),
        ),
        const SizedBox(height: 24),
        Text(
          s.t('payment_success').toUpperCase(),
          style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
              color: AppColors.onSurface),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _failedView(Strings s, {bool expired = false}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        Container(
          width: 96,
          height: 96,
          decoration: const BoxDecoration(
            color: Color(0x1AB3261E),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(
            expired ? Icons.timer_off : Icons.error_outline,
            size: 56,
            color: const Color(0xFFB3261E),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          expired ? s.t('payment_expired') : s.t('payment_failed'),
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5),
        ),
        if (_statusMsg.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(_statusMsg,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.onSurfaceVariant)),
        ],
        if (_statusDetails != null && _statusDetails!.isNotEmpty) ...[
          const SizedBox(height: 12),
          ExpansionTile(
            title: const Text('Подробнее',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(
                  _statusDetails!,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: AppColors.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _bottomActions(Strings s) {
    if (_state == _State.failed || _state == _State.expired) {
      return Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(s.t('payment_cancel')),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton(
              onPressed: _startFlow,
              child: Text(s.t('try_again')),
            ),
          ),
        ],
      );
    }
    if (_state == _State.waiting) {
      return TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(s.t('payment_cancel')),
      );
    }
    return const SizedBox.shrink();
  }
}
