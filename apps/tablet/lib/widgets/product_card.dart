import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../board/board_client.dart';
import '../models/product.dart';
import '../services/device_storage.dart';
import '../services/strings.dart';
import '../services/vending_service.dart';
import '../theme.dart';
import 'product_thumb.dart';

// ─────────────────────────── Card ───────────────────────────

/// Height of the name + price strip under the photo. Constant on purpose:
/// two 14-sp lines (≈34) plus 6 top / 10 bottom padding, with a few dp of
/// slack for system font scaling. The photo above it absorbs the difference
/// when the card shrinks, so the text never gets squeezed out no matter how
/// many columns the operator picks.
const double _kTextStripHeight = 54;

class ProductCard extends StatelessWidget {
  const ProductCard({
    super.key,
    required this.product,
    this.interactive = true,
  });

  final Product product;

  /// False renders the card as a still picture: no add button, no counter
  /// pill, no taps. Used by the storefront-settings preview, which must
  /// show the real card (same widget, no drift) without letting the
  /// operator fill a customer's cart from the service menu.
  final bool interactive;

  /// Adds one to the cart, but only if the board is currently healthy.
  /// We deliberately use the synchronous [BoardClient.isHealthy] flag
  /// here (not an awaited ping) — every tap should feel instant. The
  /// payment screen does the heavier "live ping" check before money
  /// changes hands; here it's enough to refuse the add if the
  /// recent-comm watchdog has already flagged the bus as broken.
  void _tryAdd(BuildContext context) {
    final svc = context.read<VendingService>();
    final board = context.read<BoardClient>();
    // Debug builds skip the board-health gate so UI/payment can be
    // tested on a tablet with no M102 wired up.
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
    final svc = context.watch<VendingService>();
    final cartItem = svc.cartItems
        .where((i) => i.product.motorId == product.motorId)
        .firstOrNull;
    final count = cartItem?.quantity ?? 0;
    final canAdd = count < product.stock;

    // Default state — thin gray hairline border, no shadow. The
    // shadow is reserved for the "selected" state (already in cart)
    // so the customer can see at a glance which cards they've
    // touched. Cards without a shadow read as flat content; the
    // shadow makes the selected ones lift off the page.
    final selected = count > 0;

    // Slot number from the machine layout, shown only when the operator
    // enabled it in «Витрина». Null when the layout has no slot for this
    // motor (product assigned before the layout was built) — nothing to
    // show then, and a wrong number is worse than none.
    final showSlot = context.watch<DeviceStorage>().showSlotNumber;
    final slotLabel =
        showSlot ? svc.layout.slotForMotor(product.motorId)?.label : null;
    final hasPhoto = (product.imageUrl ?? '').isNotEmpty;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      // ShapeDecoration (not BoxDecoration) so the rounded clip is
      // antialiased cleanly. No outline in either state — selection
      // is communicated by the brighter [iosCardSelectedShadow] drop
      // shadow alone.
      decoration: ShapeDecoration(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        shadows: selected ? iosCardSelectedShadow : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: (interactive && canAdd) ? () => _tryAdd(context) : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ─── Image area: whatever is left after the text strip.
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ColoredBox(
                        color: AppColors.iosBackground,
                        // The photo keeps its original edge-to-edge cover
                        // rendering. Only the two fallbacks — emoji and slot
                        // number — scale with the box: their fixed 56-dp and
                        // 16-dp sizes were tuned for the big 2-column card
                        // and swallowed the small one.
                        child: LayoutBuilder(
                          builder: (context, c) {
                            final short = c.maxWidth < c.maxHeight
                                ? c.maxWidth
                                : c.maxHeight;
                            // No photo and the operator wants numbers: put
                            // the slot number where the picture would be. A
                            // big digit is far more useful to someone at the
                            // cabinet than the generic 📦 fallback.
                            if (slotLabel != null && !hasPhoto) {
                              return Center(
                                child: Padding(
                                  padding: EdgeInsets.all(short * 0.12),
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      slotLabel,
                                      style: const TextStyle(
                                        color: AppColors.iosBlack,
                                        fontSize: 64,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: -1,
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }
                            // cover, edge to edge — the photo fills the card
                            // the way it always has. Only the emoji fallback
                            // scales with the box; a real photo is left
                            // alone.
                            return ProductThumb(
                              product: product,
                              emojiSize: short * 0.42,
                              fit: BoxFit.cover,
                            );
                          },
                        ),
                      ),
                    ),
                    // Card with a photo — the number rides in a small badge
                    // at the bottom-left, clear of the counter pill (top
                    // left) and the add button (top right).
                    if (slotLabel != null && hasPhoto)
                      Positioned(
                        bottom: 10,
                        left: 12,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.92),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            child: Text(
                              slotLabel,
                              style: const TextStyle(
                                color: AppColors.iosBlack,
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                      ),
                    // Counter pill on the left, blue plus on the right —
                    // mirrors the Figma "Selected" Card state. Counter pill
                    // is hidden until at least one is in the cart.
                    //
                    // Laid out as one spaceBetween Row rather than two
                    // independently positioned children: pinned separately
                    // to left: 12 / right: 12 they overlapped on a narrow
                    // card (3 columns, long "12" counter), the plus sitting
                    // on top of the pill. In a Row they share the width and
                    // the pill gives way instead of colliding.
                    if (interactive)
                      Positioned(
                        top: 12,
                        left: 12,
                        right: 12,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (count > 0)
                              Flexible(
                                child: _CounterPill(
                                  count: count,
                                  onRemove: () =>
                                      svc.removeOne(product.motorId),
                                ),
                              )
                            else
                              const SizedBox.shrink(),
                            _AddButton(
                              enabled: canAdd,
                              onTap: canAdd ? () => _tryAdd(context) : null,
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              // ─── Content area (name + price).
              //
              // FIXED height, not a flex share of the card. It used to be
              // flex 60 against the image's 200, so at 3 columns — where the
              // card is roughly half as tall — the strip shrank to ~17 dp of
              // usable space while the fonts stayed put, and the name and
              // price were cut off. The text needs a constant number of dp
              // (two 14-sp lines + padding); only the photo should give way
              // as cards get smaller.
              SizedBox(
                height: _kTextStripHeight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                  child: Row(
                    // Bottom-aligned so the price sits in the card's
                    // bottom-right corner regardless of whether the name
                    // wrapped to one line or two.
                    crossAxisAlignment: CrossAxisAlignment.end,
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
                      // NOT Flexible: that gave the price a flex of 1 against
                      // the name's Expanded, so the row split its width in
                      // half and the price started at the middle of the card
                      // instead of hugging its right edge — and the FittedBox
                      // alignment could not fix it, because a loose Flexible
                      // shrinks to its child and leaves nothing to align in.
                      //
                      // Laid out first at its natural width instead, with the
                      // name's Expanded taking whatever is left. A long name
                      // now ellipsises rather than squeezing the price, which
                      // is the right trade: the price is the one number the
                      // customer must be able to read.
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.bottomRight,
                        child: Text(
                          '${product.priceTenge} ₸',
                          maxLines: 1,
                          style: const TextStyle(
                            color: AppColors.iosOrange,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.18,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Round blue "+" button overlaid on the card's image — matches the
/// Figma "Menu - Nothing Selected" spec: solid blue 44-dp circle, no
/// white outline ring, soft drop shadow underneath.
class _AddButton extends StatelessWidget {
  const _AddButton({required this.enabled, required this.onTap});

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

/// Red rounded pill shown on the top-left of a product's image once
/// at least one is in the cart. The whole pill is a single tap target
/// that removes one — the white minus circle inside is purely visual
/// (no nested gesture). Operators on the kiosk preferred a bigger
/// hit area to the tiny 28-dp minus circle.
class _CounterPill extends StatelessWidget {
  const _CounterPill({required this.count, required this.onRemove});

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
          height: 44,
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
