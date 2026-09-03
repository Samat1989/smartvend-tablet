import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../board/board_client.dart';
import '../models/cart.dart';
import '../services/device_storage.dart';
import '../services/strings.dart';
import '../services/supabase_api.dart';
import '../services/vending_service.dart';
import '../theme.dart';
import '../widgets/close_circle_button.dart';
import '../widgets/support_corner.dart';

/// Post-payment screen for the micromarket: the door opens once and the
/// customer takes the goods off the shelf themselves.
///
/// The vending counterpart, [DispenseScreen], animates a motor per item
/// because each one can fail on its own. Here there is a single physical
/// event — the lock either opened or it did not — so there is nothing to
/// animate and nothing to report per line.
///
/// Order of operations matters and is deliberate: **open first, record after**.
/// The sale is only written once the board has confirmed the command, so a
/// customer who paid for a door that never opened is not also handed a receipt
/// saying they got their goods. The payment is left uncaptured in that case and
/// the gateway returns it on its own.
///
/// На автономной плате esp-relay этого порядка нет вовсе, потому что нет ни
/// одной из двух операций: замок открывает сама плата, получив от шлюза
/// событие об оплате, и она же одним `complete-order` захватывает деньги и
/// пишет продажу с остатками. Экран тогда — чек и ничего больше; см. ветку
/// [BoardClient.isStandaloneLock] в `_run`.
class UnlockScreen extends StatefulWidget {
  const UnlockScreen({super.key});

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

enum _Phase { opening, open, failed }

class _UnlockScreenState extends State<UnlockScreen> {
  final _api = SupabaseApi();

  _Phase _phase = _Phase.opening;

  /// Замок открывает автономная плата esp-relay, а не мы. Тогда этот экран —
  /// просто чек: ни команды, ни двери, за которой можно следить.
  bool _standalone = false;

  /// How long the receipt stays up before the catalog comes back.
  ///
  /// Deliberately unrelated to the relay hold time. That number is the window
  /// in which the door *may* be opened; the lock itself relocks off its own
  /// Hall sensor the moment the door shuts, which can be five seconds or
  /// thirty. A countdown here would have been describing something that is not
  /// what actually closes the door.
  static const _successSeconds = 15;
  static const _failureSeconds = 20;

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    final board = context.read<BoardClient>();
    final storage = context.read<DeviceStorage>();
    final svc = context.read<VendingService>();
    final hold = storage.lockHoldSeconds;

    if (board.isStandaloneLock) {
      // Здесь всё уже случилось без нас: плата получила от шлюза событие об
      // оплате, сама вызвала complete-order — а это и захват денег, и запись
      // продажи с остатками одной транзакцией (`finalize_paid_order`) — и
      // только по 200 щёлкнула реле. Написать продажу отсюда значило бы
      // завести вторую и списать товар дважды.
      //
      // Инвариант «open first, record after» не нарушен, а вырожден: обеих
      // операций у нас нет, остаётся показать чек.
      setState(() {
        _standalone = true;
        _phase = _Phase.open;
      });
      _scheduleReturn(_successSeconds);
      // Забрать защёлкнутый paymentId, хотя писать им нечего: пока он висит,
      // VendingService считает, что продажа не закончена, и откладывает
      // отвязку машины владельцем (см. ветку 'released' в ping). Здесь
      // продажа закончена в тот момент, когда её записал сервер.
      svc.consumePaymentId();
      if (!mounted) return;
      await svc.reload(silent: true);
      svc.clearCart();
      return;
    }

    final opened = await board.openLock(seconds: hold);
    if (!mounted) return;

    if (!opened) {
      setState(() => _phase = _Phase.failed);
      // No sale row: nothing was handed over. The payment stays uncaptured,
      // which is what makes the refund automatic.
      _scheduleReturn(_failureSeconds);
      return;
    }

    setState(() => _phase = _Phase.open);
    _scheduleReturn(_successSeconds);
    await _recordSale(svc, storage);
  }

  /// Writes the sale with every line marked delivered.
  ///
  /// There is no per-item confirmation to be had from a lock, and the door did
  /// open, so the honest record is "the customer was given access to all of
  /// it". Shortfalls surface at stock-taking, which a trust-based micromarket
  /// needs anyway.
  Future<void> _recordSale(VendingService svc, DeviceStorage storage) async {
    final openedLabel = context.read<Strings>().t('unlock_opened');
    final machid = storage.machid;
    final secret = storage.secret;
    final paymentId = svc.consumePaymentId();
    if (machid == null || secret == null || paymentId == null) return;

    try {
      final saleId = await _api.createSale(
        machid: machid,
        secret: secret,
        paymentId: paymentId,
        expectedTotalTenge: svc.cartTotalTenge,
      );
      if (saleId != null) {
        for (final item in svc.cartItems) {
          for (var i = 0; i < item.quantity; i++) {
            await _api.recordSaleItem(
              machid: machid,
              secret: secret,
              saleId: saleId,
              step: DispenseStepResult(
                product: item.product,
                outcome: DispenseOutcome.ok,
                message: openedLabel,
              ),
            );
          }
        }
        await _api.completeSale(machid: machid, secret: secret, saleId: saleId);
      }
    } catch (e) {
      // A failed write must not take the screen down: the door is already
      // open and the customer is taking their goods. The operator finds the
      // gap in the admin; blowing up here would only strand them.
      debugPrint('[UnlockScreen] sale not recorded: $e');
    }

    if (!mounted) return;
    await svc.reload(silent: true);
    svc.clearCart();
  }

  /// One-shot, not a per-second tick: nothing on screen counts down any more,
  /// so rebuilding once a second would be work for nobody.
  void _scheduleReturn(int seconds) {
    _timer?.cancel();
    _timer = Timer(Duration(seconds: seconds), _goHome);
  }

  void _goHome() {
    _timer?.cancel();
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final failed = _phase == _Phase.failed;

    return Scaffold(
      backgroundColor: AppColors.iosBackground,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _icon(failed),
                    const SizedBox(height: 28),
                    Text(
                      failed
                          ? s.t('dispense_failed')
                          : _phase == _Phase.opening
                              ? s.t('unlock_opening')
                              : _standalone
                                  ? s.t('unlock_paid_ok')
                                  : s.t('dispense_done'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: AppColors.iosBlack,
                      ),
                    ),
                    if (failed) ...[
                      const SizedBox(height: 12),
                      Text(
                        s.t('unlock_failed_hint'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 15,
                          color: AppColors.iosGray,
                          height: 1.35,
                        ),
                      ),
                    ],
                    if (_phase == _Phase.open) ...[
                      const SizedBox(height: 14),
                      Text(
                        s.t('unlock_thanks'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                          color: AppColors.iosBlack,
                        ),
                      ),
                      const SizedBox(height: 6),
                      // Просьба закрыть дверь — не вежливость, а единственный
                      // способ её закрыть: датчика двери пока нет, замок
                      // защёлкнется по таймеру, и оставленная открытой дверь
                      // это окно для выноса товара.
                      //
                      // В автономном режиме дверью распоряжается плата, и
                      // момент, когда она откроется, планшету неизвестен —
                      // просить закрыть то, что при нас ещё не открывалось,
                      // значит сбивать покупателя. Он видит «Заберите товар».
                      Text(
                        _standalone
                            ? s.t('dispense_done')
                            : s.t('unlock_close_door'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: AppColors.iosGray,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // Only offered once the door is open or the attempt failed:
            // leaving mid-open would strand the screen on a stale state.
            if (_phase != _Phase.opening)
              Positioned(
                top: 16,
                right: 16,
                child: CloseCircleButton(onTap: _goHome),
              ),
            const Positioned(
              right: 16,
              bottom: 16,
              child: SupportCorner(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _icon(bool failed) {
    return Container(
      width: 132,
      height: 132,
      decoration: BoxDecoration(
        color: failed
            ? const Color(0xFFFFE5E5)
            : _phase == _Phase.opening
                ? const Color(0xFFE8EAF6)
                : const Color(0xFFE3F7E8),
        shape: BoxShape.circle,
      ),
      child: Icon(
        failed
            ? Icons.lock
            : _phase == _Phase.opening
                ? Icons.hourglass_top
                // Открытый замок — картинка про то, что сделали мы. В
                // автономном режиме мы этого не делали и подтвердить не
                // можем, поэтому галочка об оплате: ровно то, что известно.
                : _standalone
                    ? Icons.check_circle_outline
                    : Icons.lock_open,
        size: 64,
        color: failed
            ? const Color(0xFFFF3B30)
            : _phase == _Phase.opening
                ? AppColors.iosBlue
                : const Color(0xFF34C759),
      ),
    );
  }
}
