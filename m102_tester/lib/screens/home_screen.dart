import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../board/board_client.dart';
import '../models/product.dart';
import '../services/climate_controller.dart';
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
  String _search = '';
  String? _selectedCategoryId;
  // Hidden service entry: 5 quick taps on the logo within 2 seconds.
  final List<DateTime> _logoTaps = [];

  void _onLogoTap() {
    final now = DateTime.now();
    _logoTaps
      ..add(now)
      ..removeWhere((t) => now.difference(t) > const Duration(seconds: 2));
    if (_logoTaps.length >= 5) {
      _logoTaps.clear();
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
                _Header(onLogoTap: _onLogoTap),
                _SearchBar(
                  value: _search,
                  onChanged: (v) => setState(() => _search = v),
                ),
                _CategoryChips(
                  selectedId: _selectedCategoryId,
                  onSelect: (id) =>
                      setState(() => _selectedCategoryId = id),
                ),
                Expanded(
                  child: _Body(
                    search: _search,
                    categoryId: _selectedCategoryId,
                  ),
                ),
              ],
            ),
            if (svc.cartCount > 0 && !boardDown) const _FloatingCartBar(),
            if (boardDown) _MaintenanceOverlay(onLogoTap: _onLogoTap),
          ],
        ),
      ),
    );
  }
}

/// Full-screen "out of service" curtain shown when the M102 board is
/// either disconnected or hasn't responded to the last 4 commands.
class _MaintenanceOverlay extends StatelessWidget {
  const _MaintenanceOverlay({required this.onLogoTap});

  final VoidCallback onLogoTap;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onLogoTap,
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

class _Header extends StatelessWidget {
  const _Header({required this.onLogoTap});

  final VoidCallback onLogoTap;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final storage = context.watch<DeviceStorage>();
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      decoration: const BoxDecoration(
        // glassmorphism approximation — the customer_web uses 80% opacity
        // background + backdrop blur. Solid 88% is visually similar
        // without the GPU cost of BackdropFilter on the kiosk.
        color: Color(0xE0FAF5FB),
        border: Border(
          bottom: BorderSide(
              color: AppColors.surfaceContainerHigh, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: onLogoTap,
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: const BoxDecoration(
                    color: Color(0x1A9C3F00), // primary @ 10%
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.shopping_bag_outlined,
                      color: AppColors.primary, size: 20),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.t('app_title'),
                        style: const TextStyle(
                            color: AppColors.primary,
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.8)),
                    Text(
                      '№${storage.machid ?? '—'}',
                      style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5,
                          color: AppColors.onSurfaceVariant),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Spacer(),
          const _ClimateBadge(),
          const SizedBox(width: 4),
          const _LangSwitcher(),
        ],
      ),
    );
  }
}

class _LangSwitcher extends StatelessWidget {
  const _LangSwitcher();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    return PopupMenuButton<String>(
      tooltip: '',
      icon: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.language, color: AppColors.primary, size: 20),
          const SizedBox(width: 4),
          Text(
            s.lang.toUpperCase() == 'KK' ? 'KZ' : s.lang.toUpperCase(),
            style: const TextStyle(
                color: AppColors.primary,
                fontWeight: FontWeight.bold,
                fontSize: 12),
          ),
        ],
      ),
      onSelected: (code) => s.setLang(code),
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'ru', child: Text('Русский')),
        PopupMenuItem(value: 'kk', child: Text('Қазақша')),
        PopupMenuItem(value: 'en', child: Text('English')),
      ],
    );
  }
}

class _ClimateBadge extends StatelessWidget {
  const _ClimateBadge();

  @override
  Widget build(BuildContext context) {
    return Consumer<ClimateController>(
      builder: (context, climate, _) {
        final t = climate.temperatureC;
        if (t == null) return const SizedBox.shrink();
        final tStr = '${t.toStringAsFixed(1)}°';
        final compressing = climate.compressorOn;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: compressing
                ? const Color(0xFFE3F2FD)
                : AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                compressing ? Icons.ac_unit : Icons.thermostat,
                size: 14,
                color: compressing
                    ? Colors.lightBlue
                    : AppColors.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(tStr,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: compressing
                          ? Colors.lightBlue.shade800
                          : AppColors.onSurfaceVariant)),
            ],
          ),
        );
      },
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: TextField(
        decoration: const InputDecoration(
          hintText: '...',
          prefixIcon: Icon(Icons.search,
              color: AppColors.onSurfaceVariant, size: 20),
          fillColor: AppColors.surfaceContainerLow,
          filled: true,
          contentPadding:
              EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        ),
        onChanged: onChanged,
      ),
    );
  }
}

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
  const _Body({required this.search, required this.categoryId});

  final String search;
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
            final query = search.toLowerCase();
            final filtered = svc.catalog.where((p) {
              if (p.stock <= 0) return false;
              if (!p.name.toLowerCase().contains(query)) return false;
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
                // Slightly taller than wide so name + price + stepper all
                // get vertical headroom even at narrow phone widths.
                childAspectRatio: 0.66,
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
        color: AppColors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [appCardShadow],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          // Whole card is tappable — first tap adds to cart, subsequent
          // taps work too (up to stock). Once count > 0 the inline
          // stepper at the bottom takes over for fine control.
          onTap: canAdd ? () => svc.addToCart(product) : null,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Thumbnail uses Expanded so it shrinks/grows with the
                // available card height and never overflows. The shelf
                // label is overlaid as a small badge so the customer can
                // glance from the screen to the physical sticker on the
                // machine and confirm they're at the right slot.
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            color: AppColors.surfaceContainerLow,
                            alignment: Alignment.center,
                            child: ProductThumb(
                              product: product,
                              emojiSize: 56,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 6,
                        left: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 3),
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
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  product.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppColors.onSurface,
                    letterSpacing: -0.2,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    RichText(
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: '${product.priceTenge} ',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                              color: AppColors.primary,
                              letterSpacing: -0.4,
                            ),
                          ),
                          const TextSpan(
                            text: '₸',
                            style: TextStyle(
                              fontSize: 11,
                              color: Color(0xCC9C3F00),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.inventory_2_outlined,
                              size: 10,
                              color: AppColors.onSurfaceVariant),
                          const SizedBox(width: 3),
                          // Show what's left AFTER the customer's cart, not
                          // the raw DB stock — otherwise the counter
                          // wouldn't visibly drop as they tap, which is the
                          // bug "после выбора товара не уменьшается остаток".
                          Text(
                            '${(product.stock - count).clamp(0, product.stock)}',
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: AppColors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (count > 0) ...[
                  const SizedBox(height: 8),
                  _InlineStepper(
                    count: count,
                    canAdd: canAdd,
                    onMinus: () => svc.removeOne(product.motorId),
                    onPlus: () => svc.addToCart(product),
                  ),
                ],
              ],
            ),
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
