import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../board/board_client.dart';
import '../models/product.dart';
import '../services/strings.dart';
import '../services/vending_service.dart';
import '../theme.dart';
import '../widgets/close_circle_button.dart';
import '../widgets/action_pill.dart';
import '../widgets/product_thumb.dart';
import 'payment_screen.dart';

/// Cart preview ported from Figma "Checkout - One Item Unselected".
/// Customer sees the products they've picked as a 2-col grid (same
/// card style as the catalog, just smaller content area), and
/// confirms with the bottom Pay button. BtnBack returns to the
/// catalog.
///
/// Auto-closes back to the catalog the moment the cart goes empty —
/// the customer keeps tapping the red counter pills to remove items
/// and once there's nothing left, sitting on a "Корзина пуста"
/// screen would be a dead end.
class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  late final VendingService _svc;

  @override
  void initState() {
    super.initState();
    _svc = context.read<VendingService>();
    _svc.addListener(_maybeClose);
  }

  @override
  void dispose() {
    _svc.removeListener(_maybeClose);
    super.dispose();
  }

  void _maybeClose() {
    if (!mounted) return;
    // Only auto-pop when this CartScreen is the visible top route.
    // Otherwise a clearCart() fired by the dispense flow (which sits
    // ABOVE us in the stack) would `Navigator.pop()` the dispense
    // screen instead of us — the user would land on an empty cart
    // mid-dispense, which is exactly the "после оплаты возврат во
    // пустую корзину" bug.
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return;
    if (_svc.cartIsEmpty && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    return Scaffold(
      backgroundColor: AppColors.iosBackground,
      body: SafeArea(
        child: Consumer<VendingService>(
          builder: (context, svc, _) {
            final items = svc.cartItems;
            return Stack(
              // expand: non-positioned children fill the Stack regardless
              // of their natural size. Without this, a short
              // SingleChildScrollView (few cart items) made the Stack
              // shrink-wrap to its content height and the bottom bar
              // pinned to *its* bottom — visually sitting near the top
              // of the screen instead of the screen's actual bottom.
              fit: StackFit.expand,
              children: [
                _CartList(items: items, title: s.t('cart').toUpperCase()),
                _BottomBar(
                  enabled: items.isNotEmpty,
                  total: svc.cartTotalTenge,
                  payLabel: s.t('pay_btn'),
                ),
                // Top-right cancel — clears the cart and returns to the
                // catalog. Same widget + position as the payment /
                // dispense X so the affordance reads consistently
                // across the post-cart flow.
                Positioned(
                  top: 16,
                  right: 16,
                  child: CloseCircleButton(
                    onTap: () {
                      svc.clearCart();
                      Navigator.of(context).popUntil((r) => r.isFirst);
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _CartList extends StatelessWidget {
  const _CartList({required this.items, required this.title});

  final List items;
  final String title;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    if (items.isEmpty) {
      return Center(
        child: Text(
          s.t('cart_empty'),
          style: const TextStyle(
            color: AppColors.iosGray,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 120),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: AppColors.iosBlack,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, c) {
              final cols = c.maxWidth >= 720 ? 3 : 2;
              return GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: cols,
                mainAxisSpacing: 18,
                crossAxisSpacing: 18,
                childAspectRatio: 0.895, // 215 × 240 on the 533-dp tablet
                children: [
                  for (final item in items)
                    _CartItemCard(
                      product: item.product,
                      quantity: item.quantity,
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Cart card. Same shape as the catalog card but in Figma "Selected"
/// state — counter pill (qty + red minus) on the left, blue "+" on
/// the right. Tap minus → remove one, tap plus → add another up to
/// available stock.
class _CartItemCard extends StatelessWidget {
  const _CartItemCard({required this.product, required this.quantity});

  final Product product;
  final int quantity;

  /// Same board-healthy gate as on the catalog (see [_ProductCard._tryAdd]
  /// in home_screen.dart): refuse to grow the cart if the bus is
  /// already flagged unhealthy, so the customer can't pile on items
  /// the dispenser can't actually deliver. Debug builds skip the
  /// check so the UI/payment flow works on a tablet with no M102.
  void _tryAdd(BuildContext context) {
    final svc = context.read<VendingService>();
    final board = context.read<BoardClient>();
    if (!kDebugMode && !board.isHealthy) {
      final s = context.read<Strings>();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(s.t('board_not_found')),
          backgroundColor: const Color(0xFFB3261E),
        ),
      );
      return;
    }
    svc.addToCart(product);
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.read<VendingService>();
    final canAdd = quantity < product.stock;
    // Stack pattern: card content gets clipped to a rounded rect, then
    // the blue outline is drawn in its own layer on top (Positioned.fill
    // + Border.all). This avoids the antialias-mismatch you get when
    // ShapeDecoration paints its own stroke onto the same path that
    // clips its child — the corners can lose their rounding because the
    // clip and the stroke are anti-aliased independently.
    return Stack(
      children: [
        Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.all(Radius.circular(20)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
            flex: 200,
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
                Positioned(
                  top: 12,
                  left: 12,
                  child: _CartCounterPill(
                    count: quantity,
                    onRemove: () => svc.removeOne(product.motorId),
                  ),
                ),
                Positioned(
                  top: 12,
                  right: 12,
                  child: _CartAddButton(
                    enabled: canAdd,
                    onTap:
                        canAdd ? () => _tryAdd(context) : null,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 60,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      product.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.iosBlack,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.14,
                        height: 1.2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${product.priceTenge * quantity} ₸',
                    style: const TextStyle(
                      color: AppColors.iosOrange,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.18,
                    ),
                  ),
                ],
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
                border: Border.all(color: AppColors.iosBlue, width: 2),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Local copy of the catalog screen's counter pill (intentionally not
/// shared via a `widgets/` file — the two screens are likely to diverge
/// as the design evolves and a shared widget tempts premature
/// abstraction).
class _CartCounterPill extends StatelessWidget {
  const _CartCounterPill({required this.count, required this.onRemove});

  final int count;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFE53935),
      shape: const StadiumBorder(),
      elevation: 1,
      shadowColor: const Color(0x14000000),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onRemove,
        child: SizedBox(
          height: 32,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 6, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$count',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                    height: 1,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 28,
                  height: 28,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.remove,
                    color: Color(0xFFE53935),
                    size: 18,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CartAddButton extends StatelessWidget {
  const _CartAddButton({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: enabled
            ? AppColors.iosBlue
            : AppColors.iosGray.withValues(alpha: 0.6),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: const SizedBox(
            width: 44,
            height: 44,
            child: Icon(Icons.add, color: Colors.white, size: 24),
          ),
        ),
      ),
    );
  }
}

/// Same bottom layout as the home screen — round back button + action
/// pill in its "pay" variant. Tap the back button to return to the
/// catalog; tap the pill to push the payment QR screen.
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.enabled,
    required this.total,
    required this.payLabel,
  });

  final bool enabled;
  final int total;
  final String payLabel;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      // Two-layer container: top half fades the scroll content into
      // the bar; bottom half is the solid bar background that hosts
      // back + pill. Stops the cards from peeking through the gap
      // between back-button and pill at the very bottom of the scroll.
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0x00F2F2F7),
              Color(0xFFF2F2F7),
              Color(0xFFF2F2F7),
            ],
            stops: [0.0, 0.45, 1.0],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              RoundBackButton(onTap: () => Navigator.of(context).pop()),
              const SizedBox(width: 12),
              ActionPill(
                icon: Icons.qr_code_2,
                label: payLabel,
                value: '$total ₸',
                filled: true,
                onTap: enabled ? () => _goToPayment(context) : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _goToPayment(BuildContext context) async {
    final s = context.read<Strings>();
    final board = context.read<BoardClient>();
    final navigator = Navigator.of(context);
    // Debug builds short-circuit the live ping so payment can be
    // walked through on a tablet with no M102 wired up. Production
    // keeps the strict pre-payment check so we never charge for a
    // dispense we can't deliver.
    if (kDebugMode) {
      navigator.push(
        MaterialPageRoute(builder: (_) => const PaymentScreen()),
      );
      return;
    }
    // Live ping the board before letting the customer enter payment.
    // A stale `isConnected` is not enough — port may be open but the
    // bus dead, in which case we'd take money for a sale we can't
    // dispense. The ping uses a short timeout so the spinner is brief.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: AppColors.iosBlack),
      ),
    );
    final alive = await board.ping();
    if (!context.mounted) return;
    navigator.pop(); // dismiss the spinner
    if (!alive) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(s.t('board_not_found')),
          backgroundColor: const Color(0xFFB3261E),
        ),
      );
      return;
    }
    navigator.push(
      MaterialPageRoute(builder: (_) => const PaymentScreen()),
    );
  }
}
