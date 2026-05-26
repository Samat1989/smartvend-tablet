import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../board/board_client.dart';
import '../models/cart.dart';
import '../models/product.dart';
import '../services/device_storage.dart';
import '../services/strings.dart';
import '../services/supabase_api.dart';
import '../services/vending_service.dart';
import '../theme.dart';
import '../widgets/close_circle_button.dart';
import '../widgets/product_thumb.dart';

/// Dispense / Success screen ported from Figma "Success".
///
/// Layout: header ("ЗАБЕРИТЕ ВАШИ ТОВАРЫ" with checkmark) → grid of
/// product cards → optional refund banner → auto-return countdown.
/// What's different from the Figma static state: each card has an
/// animated colored border that reflects per-motor progress —
///   neutral   = waiting in queue
///   pulsing   = motor is turning right now
///   green     = drop sensor confirmed delivery
///   red       = motor finished but no drop / overload / etc → refund
///
/// We drive the dispense ourselves (not via `VendingService.dispenseAll`)
/// so we can update `_currentMotorIndex` between each motor's call —
/// without that, the UI would only know about completed motors and
/// can't show "in progress" feedback.
class DispenseScreen extends StatefulWidget {
  const DispenseScreen({super.key});

  @override
  State<DispenseScreen> createState() => _DispenseScreenState();
}

class _DispenseScreenState extends State<DispenseScreen>
    with SingleTickerProviderStateMixin {
  final _api = SupabaseApi();

  /// Flat list — one entry per physical dispense. A cart line
  /// `[Coca × 2]` becomes two entries here. Index is the order of
  /// dispense and is used as the key into [_results].
  late final List<Product> _queue;

  /// Result per queue index. null = not processed yet.
  final Map<int, DispenseStepResult> _results = {};

  /// Currently-dispensing queue index, or null when idle (before any
  /// dispense or after all are done). Used to highlight that card.
  int? _currentIndex;

  bool _done = false;
  bool _saving = false;

  /// Pulse controller for the "in progress" border animation.
  late final AnimationController _pulse;

  // Auto-return countdown.
  int _returnSecondsLeft = 0;
  Timer? _returnTimer;
  static const _returnSecondsOk = 8;
  static const _returnSecondsWithFailure = 15;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      duration: const Duration(milliseconds: 1100),
      vsync: this,
    )..repeat(reverse: true);

    final svc = context.read<VendingService>();
    _queue = [
      for (final item in svc.cartItems)
        for (var i = 0; i < item.quantity; i++) item.product,
    ];

    // Kick off dispensing right away.
    WidgetsBinding.instance.addPostFrameCallback((_) => _runQueue());
  }

  @override
  void dispose() {
    _pulse.dispose();
    _returnTimer?.cancel();
    super.dispose();
  }

  Future<void> _runQueue() async {
    final svc = context.read<VendingService>();
    final board = context.read<BoardClient>();
    final sensor = context.read<DeviceStorage>().dispenseSensorMode;

    for (var i = 0; i < _queue.length; i++) {
      if (!mounted) return;
      setState(() => _currentIndex = i);
      final product = _queue[i];
      // Resolve motor IDs via the operator-built layout: twin spirals
      // map one product to multiple motors, all of which must fire.
      // Fallback to the bare product.motorId for backward compat when
      // the layout doesn't list this motor yet.
      final slot = svc.layout.slotForMotor(product.motorId);
      final motorIds = slot?.motorIds ?? [product.motorId];
      final DispenseResult r;
      // Debug builds with no live board fake a successful dispense so
      // the payment / receipt UI can be walked through end-to-end on
      // a tablet that isn't wired up. Production / release paths
      // always go through the real M102 protocol below.
      if (kDebugMode && !board.isConnected) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
        r = DispenseResult(
          success: true,
          message: 'DEBUG: mocked dispense OK',
        );
      } else {
        r = await board.dispenseSlot(
          motorIds,
          type: product.motorType,
          curtain: sensor,
        );
      }
      if (!mounted) return;
      final step = DispenseStepResult(
        product: product,
        success: r.success,
        message: r.message,
        resultCode: r.finalStatus?.result,
      );
      setState(() {
        _results[i] = step;
        _currentIndex = null;
      });
      // Optimistically decrement the local stock on success so subsequent
      // refresh shows the right number.
      if (r.success) {
        svc.replaceProduct(
          product.copyWith(stock: product.stock - 1),
        );
      }
    }

    if (!mounted) return;
    setState(() {
      _done = true;
      _saving = true;
    });
    await _recordSale(svc);
    if (!mounted) return;
    setState(() => _saving = false);
    _startReturnCountdown();
  }

  Future<void> _recordSale(VendingService svc) async {
    final storage = context.read<DeviceStorage>();
    final machid = storage.machid;
    final paymentId = svc.consumePaymentId();
    if (machid == null || paymentId == null || _results.isEmpty) return;
    final total = _results.values
        .where((r) => r.success)
        .fold<int>(0, (s, r) => s + r.product.priceTenge);
    await _api.recordSale(
      machid: machid,
      totalTenge: total,
      paymentId: paymentId,
      items: _results.values.toList(),
    );
    await svc.reload(silent: true);
    // Cart is "consumed" by dispense — the items should disappear from
    // the previous screen if the customer returns to it.
    svc.clearCart();
  }

  void _startReturnCountdown() {
    final hasFails = _results.values.any((r) => !r.success);
    setState(() {
      _returnSecondsLeft =
          hasFails ? _returnSecondsWithFailure : _returnSecondsOk;
    });
    _returnTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _returnSecondsLeft--);
      if (_returnSecondsLeft <= 0) {
        t.cancel();
        _goHomeNow();
      }
    });
  }

  void _goHomeNow() {
    _returnTimer?.cancel();
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  // ---------- aggregates for the header / banner ----------
  int get _deliveredCount =>
      _results.values.where((r) => r.success).length;
  int get _failedCount =>
      _results.values.where((r) => !r.success).length;
  int get _refundTenge => _results.values
      .where((r) => !r.success)
      .fold(0, (s, r) => s + r.product.priceTenge);

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    return PopScope(
      canPop: _done && !_saving,
      child: Scaffold(
        backgroundColor: AppColors.iosBackground,
        body: SafeArea(
          child: Stack(
            children: [
              SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 220),
                child: Column(
                  children: [
                    _Header(
                      done: _done,
                      delivered: _deliveredCount,
                      failed: _failedCount,
                      s: s,
                    ),
                    const SizedBox(height: 24),
                    LayoutBuilder(
                      builder: (context, c) {
                        // Match the catalog: 2 cols on phones, 3 on
                        // tablets, scaled down to leave room for the
                        // bottom action area.
                        final cols = c.maxWidth >= 720 ? 3 : 2;
                        return GridView.count(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          crossAxisCount: cols,
                          mainAxisSpacing: 16,
                          crossAxisSpacing: 16,
                          childAspectRatio: 1.0,
                          children: [
                            for (var i = 0; i < _queue.length; i++)
                              _DispenseCard(
                                product: _queue[i],
                                state: _stateAt(i),
                                pulse: _pulse,
                                s: s,
                              ),
                          ],
                        );
                      },
                    ),
                    if (_done && _failedCount > 0) ...[
                      const SizedBox(height: 20),
                      _RefundBanner(
                        refundTenge: _refundTenge,
                        s: s,
                      ),
                    ],
                  ],
                ),
              ),
              if (_done) _BottomBar(
                saving: _saving,
                secondsLeft: _returnSecondsLeft,
                onHome: _goHomeNow,
                s: s,
              ),
              // Top-right close — same shared widget + position as on
              // the payment screen. Only enabled once dispensing is
              // finished so we don't navigate away while motors are
              // still spinning.
              if (_done && !_saving)
                Positioned(
                  top: 16,
                  right: 16,
                  child: CloseCircleButton(onTap: _goHomeNow),
                ),
            ],
          ),
        ),
      ),
    );
  }

  _DispenseCardState _stateAt(int index) {
    if (_currentIndex == index) return _DispenseCardState.dispensing;
    final r = _results[index];
    if (r == null) return _DispenseCardState.pending;
    return r.success
        ? _DispenseCardState.success
        : _DispenseCardState.failed;
  }
}

// ───────────────────────────── Header ─────────────────────────────

class _Header extends StatelessWidget {
  const _Header({
    required this.done,
    required this.delivered,
    required this.failed,
    required this.s,
  });

  final bool done;
  final int delivered;
  final int failed;
  final Strings s;

  @override
  Widget build(BuildContext context) {
    final allOk = done && failed == 0;
    final IconData icon;
    final Color tint;
    final String title;
    if (!done) {
      icon = Icons.local_shipping_outlined;
      tint = AppColors.iosOrange;
      title = s.t('dispense_progress');
    } else if (allOk) {
      icon = Icons.check_circle;
      tint = const Color(0xFF2E7D32);
      title = s.t('dispense_done');
    } else if (failed == delivered + failed) {
      icon = Icons.error_outline;
      tint = const Color(0xFFB3261E);
      title = s.t('dispense_failed');
    } else {
      icon = Icons.warning_amber;
      tint = const Color(0xFFFF9F0A);
      title = s.t('dispense_partial');
    }
    return Column(
      children: [
        Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            color: tint.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 64, color: tint),
        ),
        const SizedBox(height: 18),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: AppColors.iosBlack,
            fontSize: 22,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 6),
        if (done)
          Text(
            'Выдано $delivered · Возврат $failed',
            style: const TextStyle(
              color: AppColors.iosGray,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.1,
            ),
          ),
      ],
    );
  }
}

// ───────────────────────── Dispense card ─────────────────────────

enum _DispenseCardState { pending, dispensing, success, failed }

class _DispenseCard extends StatelessWidget {
  const _DispenseCard({
    required this.product,
    required this.state,
    required this.pulse,
    required this.s,
  });

  final Product product;
  final _DispenseCardState state;
  final Animation<double> pulse;
  final Strings s;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, _) {
        final Color borderColor;
        final double borderWidth;
        switch (state) {
          case _DispenseCardState.pending:
            borderColor = AppColors.iosGray.withValues(alpha: 0.25);
            borderWidth = 2;
            break;
          case _DispenseCardState.dispensing:
            // Pulse between 0.55 and 1.0 opacity on the orange
            // border for the "loading along the perimeter" feel.
            borderColor = AppColors.iosOrange
                .withValues(alpha: 0.55 + 0.45 * pulse.value);
            borderWidth = 4;
            break;
          case _DispenseCardState.success:
            borderColor = const Color(0xFF2E7D32);
            borderWidth = 4;
            break;
          case _DispenseCardState.failed:
            borderColor = const Color(0xFFB3261E);
            borderWidth = 4;
            break;
        }
        // Stack pattern: card content gets clipped to a rounded rect,
        // then the colored outline is drawn on its own layer on top
        // (Positioned.fill + Border.all). Painting the stroke through
        // a separate decorated box means the rounded corners don't
        // get eaten by the antialiased clip the way they did when the
        // border was part of the same ShapeDecoration.
        return Stack(
          children: [
            Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.all(Radius.circular(20)),
                boxShadow: iosCardShadow,
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: [
              Positioned.fill(
                child: ColoredBox(
                  color: AppColors.iosBackground,
                  child: ProductThumb(
                    product: product,
                    emojiSize: 56,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              if (state == _DispenseCardState.dispensing)
                const Positioned(
                  top: 10,
                  right: 10,
                  child: _StatusBadge(
                    icon: Icons.refresh,
                    color: AppColors.iosOrange,
                  ),
                ),
              if (state == _DispenseCardState.success)
                const Positioned(
                  top: 10,
                  right: 10,
                  child: _StatusBadge(
                    icon: Icons.check,
                    color: Color(0xFF2E7D32),
                  ),
                ),
              if (state == _DispenseCardState.failed) ...[
                const Positioned(
                  top: 10,
                  right: 10,
                  child: _StatusBadge(
                    icon: Icons.close,
                    color: Color(0xFFB3261E),
                  ),
                ),
                Positioned(
                  bottom: 8,
                  left: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xCC1C1C1E),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      s.t('refund_title'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ),
              ],
              // Slot label so the customer knows where in the cabinet
              // to look for the product they just paid for.
              Positioned(
                top: 10,
                left: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xCC1C1C1E),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    product.shelfLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
                ],
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: borderColor,
                      width: borderWidth,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Icon(icon, color: Colors.white, size: 20),
    );
  }
}

// ───────────────────────── Refund banner ─────────────────────────

class _RefundBanner extends StatelessWidget {
  const _RefundBanner({required this.refundTenge, required this.s});

  final int refundTenge;
  final Strings s;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x1AB3261E),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          const Icon(Icons.account_balance_wallet,
              color: Color(0xFFB3261E), size: 32),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.t('refund_title'),
                  style: const TextStyle(
                    color: Color(0xFFB3261E),
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${s.t('refund_msg')} ($refundTenge ₸)',
                  style: const TextStyle(
                    color: AppColors.iosBlack,
                    fontSize: 13,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── Bottom bar ─────────────────────────

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.saving,
    required this.secondsLeft,
    required this.onHome,
    required this.s,
  });

  final bool saving;
  final int secondsLeft;
  final VoidCallback onHome;
  final Strings s;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        height: 200,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0x00F2F2F7),
              Color(0xE6F2F2F7),
              Color(0xFFF2F2F7),
            ],
            stops: [0.0, 0.51, 1.0],
          ),
        ),
        alignment: Alignment.bottomCenter,
        padding: const EdgeInsets.fromLTRB(32, 16, 32, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (saving)
              const Padding(
                padding: EdgeInsets.only(bottom: 10),
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
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.iosGray,
                        )),
                  ],
                ),
              )
            else if (secondsLeft > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.timer_outlined,
                        size: 14, color: AppColors.iosGray),
                    const SizedBox(width: 6),
                    Text(
                      '${s.t('auto_return_in')} '
                      '$secondsLeft ${s.t('seconds_short')}',
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.iosGray,
                          fontFeatures: [FontFeature.tabularFigures()]),
                    ),
                  ],
                ),
              ),
            Material(
              color: AppColors.iosBlack,
              borderRadius: BorderRadius.circular(1000),
              child: InkWell(
                borderRadius: BorderRadius.circular(1000),
                onTap: saving ? null : onHome,
                child: Container(
                  height: 72,
                  width: double.infinity,
                  alignment: Alignment.center,
                  child: Text(
                    s.t('home_btn').toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
