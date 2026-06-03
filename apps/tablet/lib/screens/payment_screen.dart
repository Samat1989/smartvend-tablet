import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/device_storage.dart';
import '../services/payment_service.dart';
import '../services/strings.dart';
import '../services/vending_service.dart';
import '../theme.dart';
import '../widgets/close_circle_button.dart';
import 'dispense_screen.dart';

/// Payment screen — Kaspi QR only.
///
/// Ported from Figma "Pay": large "К оплате" + amount at the top, a
/// big square QR card filling most of the screen, dismiss button in
/// the top-right corner. The Figma also had a card-payment row +
/// "Halyk QR" segmented option — both removed per request (this
/// installation supports Kaspi only).
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
  /// Rebuilds the screen once a second so the visible countdown digits
  /// tick down 60 → 0 instead of jumping by 3-s poll intervals.
  Timer? _countdownTimer;
  /// After the "ожидание истекло" screen appears, this timer pops the
  /// payment screen so the customer auto-returns to the catalog.
  Timer? _expiredReturnTimer;
  DateTime? _startedAt;

  static const _pollInterval = Duration(seconds: 3);
  static const _overallTimeout = Duration(seconds: 60);
  static const _expiredReturnDelay = Duration(seconds: 7);

  @override
  void initState() {
    super.initState();
    _startFlow();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _overallTimer?.cancel();
    _countdownTimer?.cancel();
    _expiredReturnTimer?.cancel();
    super.dispose();
  }

  Future<void> _startFlow() async {
    // Cancel any pending auto-return — the operator just chose to
    // retry, so we mustn't pop them back to the catalog mid-flow.
    _expiredReturnTimer?.cancel();
    _expiredReturnTimer = null;
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

    // Live "60 → 0" countdown ticking once a second. setState() is
    // enough — the visible label reads from _remaining() each rebuild.
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
    });

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
          await Future.delayed(const Duration(milliseconds: 500));
          if (!mounted) return;
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
          _scheduleExpiredReturn();
          break;
        case PaymentStatus.closed:
          _stopTimers();
          setState(() {
            _state = _State.failed;
            _statusMsg = 'Транзакция закрыта';
          });
          _scheduleExpiredReturn();
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
      _scheduleExpiredReturn();
    });
  }

  /// Pops the payment screen after [_expiredReturnDelay] so the
  /// customer doesn't sit on the "истекло / ошибка" screen forever.
  /// Called whenever the screen lands in a terminal non-success state.
  void _scheduleExpiredReturn() {
    _expiredReturnTimer?.cancel();
    _expiredReturnTimer = Timer(_expiredReturnDelay, () {
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
    });
  }

  void _stopTimers() {
    _pollTimer?.cancel();
    _overallTimer?.cancel();
    _countdownTimer?.cancel();
    _pollTimer = null;
    _overallTimer = null;
    _countdownTimer = null;
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final svc = context.watch<VendingService>();
    return Scaffold(
      backgroundColor: AppColors.iosBackground,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 660),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _PayHeader(
                        label: s.t('cart_total'),
                        total: svc.cartTotalTenge,
                      ),
                  const SizedBox(height: 20),
                  // Same 0.8 width factor as the QR card below so the
                  // tab pill visually anchors to the same column.
                  FractionallySizedBox(
                    widthFactor: 0.8,
                    child: _KaspiTabPill(label: 'Kaspi QR'),
                  ),
                  const SizedBox(height: 16),
                  // 80 % width — user asked the QR card itself to shrink
                  // ≈20 % so it doesn't dominate the payment screen.
                  FractionallySizedBox(
                    widthFactor: 0.8,
                    child: _KaspiQrCard(state: _state, request: _request),
                  ),
                  const SizedBox(height: 24),
                  if (_state == _State.waiting && _startedAt != null)
                    _WaitingHint(
                      waitingLabel: s.t('waiting_payment'),
                      remaining: _remaining(),
                    )
                  else if (_state == _State.failed ||
                      _state == _State.expired)
                    _FailedView(
                      s: s,
                      expired: _state == _State.expired,
                      message: _statusMsg,
                      details: _statusDetails,
                      onRetry: _startFlow,
                    ),
                    ],
                  ),
                ),
              ),
            ),
            // Top-right close — same widget on payment + dispense so
            // the position and size match across both post-cart
            // screens.
            Positioned(
              top: 16,
              right: 16,
              child: CloseCircleButton(
                onTap: () {
                  _stopTimers();
                  Navigator.of(context).pop();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Whole-second countdown — 60, 59, …, 0. Rendered as a bare
  /// integer per the design (no minutes:seconds split).
  String _remaining() {
    final elapsed = DateTime.now().difference(_startedAt!);
    final left = _overallTimeout - elapsed;
    if (left.isNegative) return '0';
    return left.inSeconds.toString();
  }
}

/// Top of the payment screen — matches Figma "Pay": centred caption
/// + amount. The blue X close button used to live inside this header
/// but moved to the outer Stack so its position is identical with the
/// dispense screen (top:16, right:16, 44×44).
class _PayHeader extends StatelessWidget {
  const _PayHeader({required this.label, required this.total});

  final String label;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: AppColors.iosGray,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.4,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '$total ₸',
          style: const TextStyle(
            color: AppColors.iosBlack,
            fontSize: 48,
            fontWeight: FontWeight.w800,
            letterSpacing: -2,
            height: 1,
          ),
        ),
      ],
    );
  }
}

/// Active "Kaspi QR" tab pill. Single option (Halyk QR was dropped
/// per request) — kept as a pill so the visual rhythm of the Figma
/// "Pay" frame stays intact.
class _KaspiTabPill extends StatelessWidget {
  const _KaspiTabPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(1000),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: const Color(0xFFF14635),
        borderRadius: BorderRadius.circular(1000),
        child: Container(
          height: 44,
          width: double.infinity, // fill the FractionallySizedBox slot
          padding: const EdgeInsets.symmetric(horizontal: 28),
          alignment: Alignment.center,
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
        ),
      ),
    );
  }
}

class _KaspiQrCard extends StatelessWidget {
  const _KaspiQrCard({required this.state, required this.request});

  final _State state;
  final PaymentRequest? request;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: iosCardShadow,
      ),
      // Kaspi brand mark sits *inside* the QR now (see _KaspiLogo
      // overlay), so the card is just the code itself — cleaner and
      // matches the user's "иконка внутри QR" ask.
      child: AspectRatio(
        aspectRatio: 1,
        child: _QrBody(state: state, request: request),
      ),
    );
  }
}

class _QrBody extends StatelessWidget {
  const _QrBody({required this.state, required this.request});

  final _State state;
  final PaymentRequest? request;

  @override
  Widget build(BuildContext context) {
    if (state == _State.creating) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.iosBlack),
      );
    }
    if (state == _State.success) {
      return const Center(
        child: Icon(Icons.check_circle,
            size: 120, color: Color(0xFF2E7D32)),
      );
    }
    if (state == _State.failed || state == _State.expired) {
      return const Center(
        child: Icon(Icons.error_outline,
            size: 120, color: Color(0xFFB3261E)),
      );
    }
    // Waiting: render the QR + Kaspi logo overlay in the centre. We
    // overlay rather than `embeddedImage` to avoid bundling a PNG and
    // to use the QR's high error-correction (H) so the masked-out
    // centre still decodes reliably.
    final code = request?.twocode ?? '';
    return Stack(
      alignment: Alignment.center,
      children: [
        QrImageView(
          data: code,
          backgroundColor: Colors.white,
          eyeStyle: const QrEyeStyle(
            eyeShape: QrEyeShape.square,
            color: AppColors.iosBlack,
          ),
          dataModuleStyle: const QrDataModuleStyle(
            dataModuleShape: QrDataModuleShape.square,
            color: AppColors.iosBlack,
          ),
          // H = ~30 % error correction. Required when we cover part
          // of the code with the logo overlay — anything lower and a
          // typical reader fails to decode.
          errorCorrectionLevel: QrErrorCorrectLevel.H,
        ),
        const _KaspiLogo(),
      ],
    );
  }
}

/// Centred Kaspi logo overlay rendered from `lib/static/Group2.png`.
/// Wrapped in a white circle so the overlay reads as a sticker on
/// top of the QR — H-level error correction (QrErrorCorrectLevel.H)
/// masks out enough modules under the overlay that the code still
/// decodes reliably from a phone camera.
class _KaspiLogo extends StatelessWidget {
  const _KaspiLogo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 80,
      height: 80,
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(4),
      child: ClipOval(
        child: Image.asset(
          'lib/static/logo_kaspi.png',
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

class _WaitingHint extends StatelessWidget {
  const _WaitingHint({required this.waitingLabel, required this.remaining});

  final String waitingLabel;
  final String remaining;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.iosBlack),
            ),
            const SizedBox(width: 10),
            Text(
              waitingLabel,
              style: const TextStyle(
                fontSize: 14,
                color: AppColors.iosGray,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        if (remaining.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            remaining,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.iosGray,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }
}

class _FailedView extends StatelessWidget {
  const _FailedView({
    required this.s,
    required this.expired,
    required this.message,
    required this.details,
    required this.onRetry,
  });

  final Strings s;
  final bool expired;
  final String message;
  final String? details;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    // Expired state shows the title + retry only. No subtext / details
    // — gives the customer one obvious action ("Повторить") plus the
    // auto-return safety net (7 s) so they aren't stuck on a dead end.
    if (expired) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            s.t('payment_expired'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              color: AppColors.iosBlack,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 20),
          FractionallySizedBox(
            widthFactor: 0.8,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.iosBlack,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(1000)),
              ),
              onPressed: onRetry,
              child: Text(
                s.t('try_again'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          s.t('payment_failed'),
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w900,
            color: AppColors.iosBlack,
            letterSpacing: -0.5,
          ),
        ),
        if (message.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.iosGray,
            ),
          ),
        ],
        if (details != null && details!.isNotEmpty) ...[
          const SizedBox(height: 12),
          ExpansionTile(
            title: const Text('Подробнее',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.iosBlack,
                )),
            tilePadding: EdgeInsets.zero,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.iosBackground,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(
                  details!,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: AppColors.iosBlack,
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 20),
        // 0.8 width factor matches the Kaspi pill and the QR card above
        // so all three sit in the same visual column.
        FractionallySizedBox(
          widthFactor: 0.8,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.iosBlack,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(1000)),
            ),
            onPressed: onRetry,
            child: Text(s.t('try_again'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                )),
          ),
        ),
      ],
    );
  }
}
