import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/cart.dart';
import '../services/device_storage.dart';
import '../services/strings.dart';
import '../services/supabase_api.dart';
import '../services/vending_service.dart';
import '../theme.dart';

class DispenseScreen extends StatefulWidget {
  const DispenseScreen({super.key});

  @override
  State<DispenseScreen> createState() => _DispenseScreenState();
}

class _DispenseScreenState extends State<DispenseScreen> {
  final _results = <DispenseStepResult>[];
  final _api = SupabaseApi();
  StreamSubscription<DispenseStepResult>? _sub;
  bool _done = false;
  bool _saving = false;

  /// Seconds left on the auto-return-home countdown. 0 means the timer
  /// hasn't started yet (still dispensing or saving). On completion it's
  /// initialised in [_startReturnCountdown] — longer for failed sessions
  /// so the customer has time to read the refund banner / take a photo.
  int _returnSecondsLeft = 0;
  Timer? _returnTimer;
  static const _returnSecondsOk = 8;
  static const _returnSecondsWithFailure = 15;

  @override
  void initState() {
    super.initState();
    final svc = context.read<VendingService>();
    _sub = svc.dispenseAll().listen(
      (r) => setState(() => _results.add(r)),
      onDone: () async {
        setState(() {
          _done = true;
          _saving = true;
        });
        await _recordSale();
        if (!mounted) return;
        setState(() => _saving = false);
        _startReturnCountdown();
      },
      onError: (_) {
        setState(() => _done = true);
        _startReturnCountdown();
      },
    );
  }

  /// Tick down [_returnSecondsLeft] once a second; on zero, pop to root.
  /// Tapping "На главную" calls [_goHomeNow] which navigates immediately
  /// (and dispose() cancels the timer naturally).
  void _startReturnCountdown() {
    _returnTimer?.cancel();
    final hasFails = _results.any((r) => !r.success);
    setState(() {
      _returnSecondsLeft =
          hasFails ? _returnSecondsWithFailure : _returnSecondsOk;
    });
    _returnTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _returnSecondsLeft--);
      if (_returnSecondsLeft <= 0) {
        timer.cancel();
        _goHomeNow();
      }
    });
  }

  void _goHomeNow() {
    _returnTimer?.cancel();
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _recordSale() async {
    if (_results.isEmpty) return;
    final storage = context.read<DeviceStorage>();
    final svc = context.read<VendingService>();
    final machid = storage.machid;
    final paymentId = svc.consumePaymentId();
    if (machid == null || paymentId == null) return;
    final total = _results
        .where((r) => r.success)
        .fold<int>(0, (s, r) => s + r.product.priceTenge);
    await _api.recordSale(
      machid: machid,
      totalTenge: total,
      paymentId: paymentId,
      items: _results,
    );
    // Reload catalog so stock numbers reflect server-side state.
    await svc.reload();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _returnTimer?.cancel();
    super.dispose();
  }

  int get _refundTenge => _results
      .where((r) => !r.success)
      .fold(0, (s, r) => s + r.product.priceTenge);
  int get _deliveredCount => _results.where((r) => r.success).length;
  int get _failedCount => _results.where((r) => !r.success).length;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final allOk = _done && _failedCount == 0;
    final hasFails = _done && _failedCount > 0;

    // Block system-back during dispensing — the motors are physically
    // turning, the customer must wait for the result; only after _done
    // do we let them tap "На главную" themselves.
    return PopScope(
      canPop: _done,
      child: Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(s.t('dispense_title').toUpperCase(),
            style: const TextStyle(
                fontWeight: FontWeight.w900,
                letterSpacing: -0.5,
                fontSize: 22)),
        automaticallyImplyLeading: false,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_done)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 28),
                child: Column(
                  children: [
                    const CircularProgressIndicator(
                        color: AppColors.primary),
                    const SizedBox(height: 16),
                    Text(s.t('dispense_progress'),
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppColors.onSurface)),
                  ],
                ),
              )
            else
              _resultHeader(s, allOk, hasFails),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.separated(
                itemCount: _results.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final r = _results[i];
                  return Container(
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainerLowest,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: const [appCardShadow],
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 6),
                      leading: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: r.success
                              ? const Color(0x1A9C3F00)
                              : const Color(0x1AB3261E),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          r.success ? Icons.check_circle : Icons.cancel,
                          color: r.success
                              ? AppColors.primary
                              : const Color(0xFFB3261E),
                          size: 24,
                        ),
                      ),
                      title: Text(
                        r.product.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            letterSpacing: -0.3),
                      ),
                      subtitle: Text(
                        '${s.t('shelf')} ${r.product.shelfLabel} — '
                        '${r.resultCode != null ? s.pollResult(r.resultCode!) : r.message}',
                        style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.onSurfaceVariant),
                      ),
                      trailing: Text(
                        r.success
                            ? '${r.product.priceTenge} ₸'
                            : s.t('refund_title'),
                        style: TextStyle(
                          color: r.success
                              ? AppColors.primary
                              : const Color(0xFFB3261E),
                          fontWeight: FontWeight.w900,
                          fontSize: 14,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (_done) ...[
              if (_saving)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 8),
                      Text('Сохранение продажи…',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                    ],
                  ),
                ),
              if (hasFails) _refundBanner(s),
              const SizedBox(height: 12),
              if (!_saving && _returnSecondsLeft > 0) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.timer_outlined,
                        size: 14,
                        color: AppColors.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Text(
                      '${s.t('auto_return_in')} '
                      '$_returnSecondsLeft ${s.t('seconds_short')}',
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.onSurfaceVariant,
                          fontFeatures: [FontFeature.tabularFigures()]),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                icon: const Icon(Icons.home),
                label: Text(s.t('home_btn')),
                onPressed: _saving ? null : _goHomeNow,
              ),
            ],
          ],
        ),
      ),
      ),
    );
  }

  Widget _resultHeader(Strings s, bool allOk, bool hasFails) {
    final IconData icon;
    final Color tint;
    final String msg;
    if (allOk) {
      icon = Icons.check_circle;
      tint = AppColors.primary;
      msg = s.t('dispense_done');
    } else if (hasFails && _deliveredCount == 0) {
      icon = Icons.error;
      tint = const Color(0xFFB3261E);
      msg = s.t('dispense_failed');
    } else {
      icon = Icons.warning_amber;
      tint = AppColors.tertiaryContainer;
      msg = s.t('dispense_partial');
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 48, color: tint),
          ),
          const SizedBox(height: 14),
          Text(msg.toUpperCase(),
              style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5)),
          const SizedBox(height: 6),
          Text(
            '+$_deliveredCount  ·  −$_failedCount',
            style: const TextStyle(
                fontSize: 13,
                color: AppColors.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5),
          ),
        ],
      ),
    );
  }

  Widget _refundBanner(Strings s) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0x1AB3261E),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Icon(Icons.account_balance_wallet,
              color: Color(0xFFB3261E), size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.t('refund_title'),
                    style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 14,
                        color: Color(0xFFB3261E))),
                const SizedBox(height: 2),
                Text(
                  '${s.t('refund_msg')} ($_refundTenge ₸)',
                  style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
