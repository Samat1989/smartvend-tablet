import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../board/board_client.dart';
import '../models/product.dart';
import '../services/device_storage.dart';
import '../services/strings.dart';
import '../services/vending_service.dart';
import '../theme.dart';
import '../widgets/product_thumb.dart';
import 'cart_screen.dart';
import 'service_pin_screen.dart';

/// Customer-facing home screen, ported in spirit and palette from
/// `customer_web/src/App.jsx`: Kinetic Gourmet warm-orange theme,
/// glass-style header, rounded chips, lifted product cards, and a
/// gradient floating cart bar.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _selectedCategoryId;
  // Hidden service entry: 5 quick taps on the machine-id corner badge
  // within 2 seconds. The badge is intentionally tiny and at the bottom-
  // right so customers don't discover it.
  final List<DateTime> _serviceTaps = [];

  void _onServiceTap() {
    final now = DateTime.now();
    _serviceTaps
      ..add(now)
      ..removeWhere((t) => now.difference(t) > const Duration(seconds: 2));
    if (_serviceTaps.length >= 5) {
      _serviceTaps.clear();
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ServicePinScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<VendingService>();
    final board = context.watch<BoardClient>();
    final boardDown = !board.isHealthy && !kDebugMode;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                // No header, no search bar — categories chips sit at the
                // very top, customer scrolls/filters via chips only.
                const SizedBox(height: 8),
                _CategoryChips(
                  selectedId: _selectedCategoryId,
                  onSelect: (id) =>
                      setState(() => _selectedCategoryId = id),
                ),
                Expanded(
                  child: _Body(categoryId: _selectedCategoryId),
                ),
              ],
            ),
            if (svc.cartCount > 0 && !boardDown) const _FloatingCartBar(),
            if (boardDown) _MaintenanceOverlay(onServiceTap: _onServiceTap),
            const _LangCorner(),
            _MachidCorner(onTap: _onServiceTap),
          ],
        ),
      ),
    );
  }
}

/// Full-screen "out of service" curtain shown when the M102 board is
/// either disconnected or hasn't responded to the last 4 commands.
class _MaintenanceOverlay extends StatelessWidget {
  const _MaintenanceOverlay({required this.onServiceTap});

  final VoidCallback onServiceTap;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onServiceTap,
        child: Container(
          color: const Color(0xEB2F2E32),
          alignment: Alignment.center,
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.build_circle,
                  size: 96, color: AppColors.primaryContainer),
              const SizedBox(height: 24),
              Text(
                s.t('maintenance_title'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                s.t('maintenance_subtitle'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xCCFFFFFF),
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// _Header removed entirely — its only remaining content (bag icon and
// language switcher) is gone or relocated. Search bar now sits at the
// top of the column, language goes into the bottom-left corner.

/// Tiny machine number in the bottom-right. Doubles as the hidden
/// 5-tap entry point to service mode (the round logo + bag-icon that
/// used to host it was removed). It's small enough that customers
/// ignore it and the operator knows where to tap.
class _MachidCorner extends StatelessWidget {
  const _MachidCorner({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final machid = context.watch<DeviceStorage>().machid;
    if (machid == null) return const SizedBox.shrink();
    return Positioned(
      right: 8,
      bottom: 6,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        // A bit of inflated padding makes the 10pt text easier to
        // hit with a finger without making the visible label larger.
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            '№$machid',
            style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
                color: Color(0x665D5B5F)),
          ),
        ),
      ),
    );
  }
}

/// Language toggle in the bottom-LEFT corner. One tap cycles through
/// ru → kk → en → ru — no popup, no list. Visually mirrors the
/// machid corner on the opposite side.
class _LangCorner extends StatelessWidget {
  const _LangCorner();

  static const _cycle = ['ru', 'kk', 'en'];

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final i = _cycle.indexOf(s.lang);
    final next = _cycle[(i + 1) % _cycle.length];
    final display = s.lang == 'kk' ? 'KZ' : s.lang.toUpperCase();
    return Positioned(
      left: 8,
      bottom: 6,
      child: Material(
        color: const Color(0xCCFFFFFF),
        shape: const StadiumBorder(),
        elevation: 1,
        shadowColor: Colors.black12,
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => s.setLang(next),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.language,
                    size: 14, color: AppColors.primary),
                const SizedBox(width: 4),
                Text(
                  display,
                  style: const TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 11,
                    letterSpacing: 0.5,
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

// _ClimateBadge removed — temperature is operator-only info, accessible
// from service mode → "Холодильник". Customers don't need it.

// _SearchBar removed — customers find products by category chips only.
// Kept _Body without the `search` filter parameter accordingly.

class _CategoryChips extends StatelessWidget {
  const _CategoryChips({
    required this.selectedId,
    required this.onSelect,
  });

  final String? selectedId;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    return Consumer<VendingService>(
      builder: (context, svc, _) {
        final cats = svc.categories;
        if (cats.isEmpty) return const SizedBox.shrink();
        return SizedBox(
          height: 56,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            children: [
              _Chip(
                label: s.t('all_categories'),
                selected: selectedId == null,
                onTap: () => onSelect(null),
              ),
              for (final c in cats) ...[
                const SizedBox(width: 10),
                _Chip(
                  label: c.localizedName(s.lang),
                  selected: selectedId == c.id,
                  onTap: () => onSelect(c.id),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: selected ? 1.05 : 1.0,
      duration: const Duration(milliseconds: 150),
      child: Material(
        color: selected
            ? AppColors.primary
            : AppColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
            child: Text(
              label,
              style: TextStyle(
                color: selected
                    ? AppColors.onPrimary
                    : AppColors.onSurfaceVariant,
                fontSize: 13,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.categoryId});

  final String? categoryId;

  @override
  Widget build(BuildContext context) {
    return Consumer<VendingService>(
      builder: (context, svc, _) {
        switch (svc.state) {
          case CatalogState.loading:
            return const Center(child: CircularProgressIndicator());
          case CatalogState.unpaired:
            return const SizedBox.shrink();
          case CatalogState.error:
            return _ErrorView(message: svc.error ?? '');
          case CatalogState.ready:
            final filtered = svc.catalog.where((p) {
              if (p.stock <= 0) return false;
              if (categoryId != null && p.categoryId != categoryId) {
                return false;
              }
              return true;
            }).toList();
            if (filtered.isEmpty) {
              return Center(
                child: Text(context.read<Strings>().t('no_products'),
                    style: const TextStyle(
                        color: AppColors.onSurfaceVariant,
                        fontSize: 14)),
              );
            }
            // The operator picks columns from the service menu; we only
            // fall back to a width-based clamp when the chosen value is
            // clearly impossible on this screen (e.g. 5 columns on a
            // 320 px phone). 90 px per column is the absolute minimum
            // before product names get unreadable.
            final width = MediaQuery.of(context).size.width;
            final stored = context.watch<DeviceStorage>().gridColumns;
            final maxByWidth = (width / 90).floor().clamp(2, 5);
            final cols = stored.clamp(2, maxByWidth);
            return GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                // Full-bleed image cards look balanced at ~3:4 portrait
                // ratio — gives enough vertical room for the name+price
                // overlay and the stepper without squashing the photo.
                childAspectRatio: 0.78,
              ),
              itemCount: filtered.length,
              itemBuilder: (_, i) => _ProductTile(product: filtered[i]),
            );
        }
      },
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: const BoxDecoration(
                color: Color(0x1AB3261E),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.cloud_off,
                  size: 36, color: Color(0xFFB3261E)),
            ),
            const SizedBox(height: 16),
            Text(s.t('fetch_error'),
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 12, color: AppColors.onSurfaceVariant)),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: Text(s.t('reload')),
              onPressed: () => context.read<VendingService>().reload(),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({required this.product});
  final Product product;

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<VendingService>();
    final cartItem = svc.cartItems
        .where((i) => i.product.motorId == product.motorId)
        .firstOrNull;
    final count = cartItem?.quantity ?? 0;
    final canAdd = count < product.stock;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [appCardShadow],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          // Whole card is tappable — first tap adds to cart, subsequent
          // taps work too. Once count > 0 the inline stepper at the
          // bottom takes over for fine control.
          onTap: canAdd ? () => svc.addToCart(product) : null,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // ---------- 1. Full-bleed image background ----------
              // No padding — the image (or emoji fallback) fills the
              // entire card edge-to-edge, like a food-delivery tile.
              Positioned.fill(
                child: ProductThumb(
                  product: product,
                  emojiSize: 72,
                  fit: BoxFit.cover,
                ),
              ),
              // ---------- 2. Dark gradient at the bottom ----------
              // Keeps the name + price readable over any image content.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  height: 110,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x002F2E32),
                        Color(0xCC2F2E32),
                        Color(0xEE2F2E32),
                      ],
                      stops: [0.0, 0.55, 1.0],
                    ),
                  ),
                ),
              ),
              // ---------- 3. Slot label badge top-left ----------
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xCC2F2E32),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    product.shelfLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.6,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              // ---------- 4. Name + price overlay at bottom ----------
              Positioned(
                left: 10,
                right: 10,
                bottom: count > 0 ? 50 : 10,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      product.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.3,
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    RichText(
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: '${product.priceTenge} ',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              color: Colors.white,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const TextSpan(
                            text: '₸',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xCCFFFFFF),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // ---------- 5. Inline stepper at bottom when in cart ----
              if (count > 0)
                Positioned(
                  left: 10,
                  right: 10,
                  bottom: 8,
                  child: _InlineStepper(
                    count: count,
                    canAdd: canAdd,
                    onMinus: () => svc.removeOne(product.motorId),
                    onPlus: () => svc.addToCart(product),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact `[-]  count  [+]` pill that replaces the static add-button
/// once a product is already in the cart. Wrapped in its own InkWell so
/// stepper taps don't bubble up to the card-level addToCart handler.
class _InlineStepper extends StatelessWidget {
  const _InlineStepper({
    required this.count,
    required this.canAdd,
    required this.onMinus,
    required this.onPlus,
  });

  final int count;
  final bool canAdd;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _StepperButton(
            icon: Icons.remove,
            onTap: onMinus,
            filled: false,
          ),
          Text(
            '$count',
            style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w900,
                color: AppColors.primary,
                letterSpacing: -0.3),
          ),
          _StepperButton(
            icon: Icons.add,
            onTap: canAdd ? onPlus : null,
            filled: true,
          ),
        ],
      ),
    );
  }
}

class _StepperButton extends StatelessWidget {
  const _StepperButton({
    required this.icon,
    required this.onTap,
    required this.filled,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Material(
      color: filled
          ? (disabled
              ? AppColors.surfaceContainerHigh
              : AppColors.primary)
          : AppColors.surfaceContainerLowest,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(
            icon,
            size: 14,
            color: filled
                ? Colors.white
                : AppColors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _FloatingCartBar extends StatelessWidget {
  const _FloatingCartBar();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final svc = context.watch<VendingService>();
    return Positioned(
      left: 16,
      right: 16,
      bottom: 16,
      child: Material(
        elevation: 10,
        shadowColor: const Color(0x339C3F00),
        borderRadius: BorderRadius.circular(999),
        child: Ink(
          decoration: BoxDecoration(
            gradient: signatureGradient,
            borderRadius: BorderRadius.circular(999),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CartScreen()),
            ),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Row(
                children: [
                  const Icon(Icons.shopping_bag_outlined,
                      color: Colors.white, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    '${svc.cartCount} ${s.t('pcs')}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        letterSpacing: 0.3),
                  ),
                  const Spacer(),
                  Text(
                    '${svc.cartTotalTenge} ₸',
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 20,
                        letterSpacing: -0.5),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.chevron_right,
                      color: Colors.white, size: 22),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
