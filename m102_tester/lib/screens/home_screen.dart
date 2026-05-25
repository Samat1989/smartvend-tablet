import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../board/board_client.dart';
import '../models/motor_layout.dart';
import '../models/product.dart';
import '../services/device_storage.dart';
import '../services/idle_service.dart';
import '../services/kiosk_bridge.dart';
import '../services/strings.dart';
import '../services/vending_service.dart';
import '../theme.dart';
import '../widgets/action_pill.dart';
import '../widgets/product_thumb.dart';
import 'cart_screen.dart';
import 'screensaver_screen.dart';
import 'service_pin_screen.dart';

/// Customer-facing catalog ported from the Figma file
/// "MicroMart / Menu - Nothing Selected".
///
/// Layout (744 dp viewport, scales fluidly):
///   • Vertical scroll on the left — one ProductGroup per physical
///     shelf (six in total). Group header is an orange-numbered square
///     plus the shelf label range (e.g. "001 — 006").
///   • Right rail — vertical pill segmented selector 1..6. Tap a number
///     to jump the list to that shelf; the tapped pill turns blue.
///   • Bottom — gradient-faded "Main Action" bar with a back button and
///     a wide cart pill that becomes opaque + bright when there are
///     items in the cart.
///
/// Maintenance overlay shows whenever the board is unhealthy — the
/// previous debug-mode mask is gone, so on the emulator without a
/// real M102 you'll see "техническая проблема". Plug in real hardware
/// (or a USB-Serial dongle) before exercising customer flows.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Shelf index → GlobalKey, lazily initialised. A Map (instead of a
  // fixed-size list) so the catalog handles operator-configured
  // layouts with any shelf count, not just the factory 6.
  final Map<int, GlobalKey> _shelfKeyCache = {};
  GlobalKey _shelfKey(int oneBased) =>
      _shelfKeyCache.putIfAbsent(oneBased, () => GlobalKey());

  /// Currently-highlighted shelf in the right-rail selector. Tap-on-tab
  /// sets it directly; scroll updates it via [_onScroll] so the rail
  /// reflects whichever shelf header is at the top of the viewport.
  int _selectedShelf = 1;

  /// Owned here so the scroll listener and the SingleChildScrollView
  /// share the same controller — passes down to [_ProductList].
  final ScrollController _scrollController = ScrollController();

  // Hidden service entry: 5 quick taps on the machid corner badge.
  final List<DateTime> _serviceTaps = [];

  /// Two-stage idle behaviour:
  ///
  ///  • After [_shelfCycleAfter] without a touch, the catalog starts
  ///    auto-advancing its right-rail selection 1 → 2 → … → N → 1 →
  ///    … so passers-by see the whole inventory without us having to
  ///    leave the catalog screen.
  ///  • After [_screensaverAfter] (longer) the full-screen attract
  ///    loop (shelves + media slideshow) takes over until the next
  ///    touch.
  ///
  /// Both timers reset on any pointer event via [_resetIdle]. While
  /// the cart has items the auto-cycle pauses — the customer is
  /// clearly mid-pick and we mustn't steal their place in the catalog.
  static const Duration _shelfCycleAfter = Duration(seconds: 30);
  static const Duration _shelfCycleStep = Duration(seconds: 10);
  static const Duration _cartAbandonAfter = Duration(minutes: 2);
  static const Duration _screensaverAfter = Duration(minutes: 5);
  Timer? _idleTick;
  DateTime? _lastShelfAdvanceAt;
  bool _screensaverOpen = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _idleTick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _idleTick?.cancel();
    super.dispose();
  }

  void _resetIdle() {
    // Pointer events at the global builder Listener already bump
    // [IdleService.instance.lastTouchAt]; this just clears our own
    // per-step state so a finger-down restarts the auto-cycle cadence
    // cleanly.
    if (_screensaverOpen) return;
    _lastShelfAdvanceAt = null;
  }

  Future<void> _onTick() async {
    if (!mounted || _screensaverOpen) return;

    final svc = context.read<VendingService>();
    final idleFor =
        DateTime.now().difference(IdleService.instance.lastTouchAt);

    // Stage 0 — abandoned cart. Runs from any route so we can pop the
    // customer back to home if they walked away on the cart / pay
    // screen without checking out. Reset the idle clock afterwards so
    // the auto-cycle / screensaver stages start fresh from "home".
    if (svc.cartCount > 0 && idleFor >= _cartAbandonAfter) {
      svc.clearCart();
      Navigator.of(context).popUntil((r) => r.isFirst);
      IdleService.instance.touched();
      _lastShelfAdvanceAt = null;
      return;
    }

    // Below stages only apply when HomeScreen is the visible route.
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return;
    // Don't interrupt a customer who's actively curating a cart.
    if (svc.cartCount > 0) return;

    if (idleFor >= _screensaverAfter) {
      _screensaverOpen = true;
      _lastShelfAdvanceAt = null;
      final nav = Navigator.of(context);
      await nav.push(MaterialPageRoute<void>(
        builder: (_) => const ScreensaverScreen(),
        fullscreenDialog: true,
      ));
      if (!mounted) return;
      _screensaverOpen = false;
      IdleService.instance.touched();
      return;
    }

    if (idleFor >= _shelfCycleAfter) {
      final lastStep = _lastShelfAdvanceAt ?? IdleService.instance.lastTouchAt;
      if (DateTime.now().difference(lastStep) >= _shelfCycleStep) {
        await _autoAdvanceShelf();
        _lastShelfAdvanceAt = DateTime.now();
      }
    }
  }

  Future<void> _autoAdvanceShelf() async {
    if (!mounted) return;
    final svc = context.read<VendingService>();
    final shelfCount = svc.layout.isNotEmpty
        ? svc.layout.shelves.length
        : MotorLayout.rows;
    if (shelfCount == 0) return;
    final next = _selectedShelf >= shelfCount ? 1 : _selectedShelf + 1;
    await _scrollToShelf(next);
  }

  /// Re-evaluates which shelf the customer is currently looking at and
  /// updates [_selectedShelf] so the right-rail tabs follow the scroll.
  /// Strategy: walk the shelves bottom-up and pick the first one whose
  /// header has scrolled to or above a "trigger line" near the top of
  /// the viewport. The 24-dp threshold matches the list's top padding
  /// so the rail flips the moment a shelf header lines up with the
  /// catalog's natural top edge.
  void _onScroll() {
    const triggerDy = 24.0 + 80.0; // list top padding + a bit of slack
    final svc = context.read<VendingService>();
    final shelfCount = svc.layout.isNotEmpty
        ? svc.layout.shelves.length
        : MotorLayout.rows;
    var detected = 1;
    for (var i = shelfCount; i >= 1; i--) {
      final ctx = _shelfKey(i).currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      final dy = box.localToGlobal(Offset.zero).dy;
      if (dy <= triggerDy) {
        detected = i;
        break;
      }
    }
    if (detected != _selectedShelf) {
      setState(() => _selectedShelf = detected);
    }
  }

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

  Future<void> _scrollToShelf(int shelf) async {
    setState(() => _selectedShelf = shelf);
    final ctx = _shelfKey(shelf).currentContext;
    if (ctx == null) return;
    await Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      alignment: 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final board = context.watch<BoardClient>();
    final boardDown = !board.isHealthy;
    return Scaffold(
      backgroundColor: AppColors.iosBackground,
      body: Listener(
        // Any touch resets the idle countdown — pointer events fire on
        // EVERY tap/scroll regardless of whether the underlying widget
        // handled it, which is exactly what we want for activity
        // detection.
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _resetIdle(),
        onPointerMove: (_) => _resetIdle(),
        child: SafeArea(
        child: Stack(
          // Force the Stack to take the full SafeArea size so the
          // Positioned(bottom: 0) action bar always sits at the
          // screen bottom regardless of how short the catalog Row is.
          fit: StackFit.expand,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _ProductList(
                    shelfKey: _shelfKey,
                    scrollController: _scrollController,
                  ),
                ),
                _ShelfSelector(
                  selected: _selectedShelf,
                  onSelect: _scrollToShelf,
                  shelfCount: context.watch<VendingService>().layout.isNotEmpty
                      ? context
                          .read<VendingService>()
                          .layout
                          .shelves
                          .length
                      : MotorLayout.rows,
                ),
              ],
            ),
            const _BottomActionBar(),
            if (boardDown) _MaintenanceOverlay(onServiceTap: _onServiceTap),
            // Order matters: MachidCorner first, LangCorner painted on top
            // so its tap area isn't shadowed by the (also tappable) machid
            // badge sitting above it.
            _MachidCorner(onTap: _onServiceTap),
            const _LangCorner(),
          ],
        ),
      ),
      ),
    );
  }
}

// ─────────────────────────── Product list ───────────────────────────

class _ProductList extends StatelessWidget {
  const _ProductList({
    required this.shelfKey,
    required this.scrollController,
  });

  /// Lazily resolves shelf index → GlobalKey so the right-rail tabs'
  /// `Scrollable.ensureVisible` can hop to any shelf regardless of
  /// how many shelves the operator configured.
  final GlobalKey Function(int oneBased) shelfKey;
  final ScrollController scrollController;

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
            // Two render paths share the same SingleChildScrollView so
            // the right-rail's `Scrollable.ensureVisible` works in both:
            //   1. Operator built a layout in service mode → use it.
            //   2. No layout configured yet → fall back to the factory
            //      6×6 [MotorLayout] grid so first-launch users still
            //      see a sensible catalog.
            final byMotor = {for (final p in svc.catalog) p.motorId: p};
            final layout = svc.layout;
            final shelves = <_RenderedShelf>[];
            if (layout.isNotEmpty) {
              for (var i = 0; i < layout.shelves.length; i++) {
                final sh = layout.shelves[i];
                final products = <Product>[];
                for (final slot in sh.slots) {
                  // First listed motor of the slot is the "anchor" the
                  // product is tagged with in inventory. Twin slots
                  // dispense all motors at run time (see VendingService).
                  final p = byMotor[slot.primaryMotorId];
                  if (p != null) products.add(p);
                }
                shelves.add(_RenderedShelf(
                  label: sh.label,
                  products: products,
                ));
              }
            } else {
              for (var s = 1; s <= MotorLayout.rows; s++) {
                shelves.add(_RenderedShelf(
                  label: MotorLayout.shelfLabelRange(s),
                  products: [
                    for (final m in MotorLayout.motorsForShelf(s))
                      if (byMotor[m] != null) byMotor[m]!,
                  ],
                ));
              }
            }
            return SingleChildScrollView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < shelves.length; i++) ...[
                    _ShelfGroup(
                      key: shelfKey(i + 1),
                      shelfNumber: i + 1,
                      label: shelves[i].label,
                      products: shelves[i].products,
                    ),
                    if (i < shelves.length - 1)
                      const SizedBox(height: 56),
                  ],
                ],
              ),
            );
        }
      },
    );
  }
}

/// Single shelf's render data — operator-supplied label + the products
/// that fall under it. Decoupled from the underlying MachineLayout /
/// MotorLayout origin so [_ShelfGroup] doesn't need to know which path
/// produced the list.
class _RenderedShelf {
  const _RenderedShelf({required this.label, required this.products});
  final String label;
  final List<Product> products;
}

class _ShelfGroup extends StatelessWidget {
  const _ShelfGroup({
    super.key,
    required this.shelfNumber,
    required this.label,
    required this.products,
  });

  final int shelfNumber;
  final String label;
  final List<Product> products;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header row: muted 25-dp numbered square + 14-pt range label.
        // Was orange/black; toned down to gray-on-gray so the shelf
        // dividers don't compete with the product cards.
        Row(
          children: [
            Container(
              width: 25,
              height: 25,
              decoration: BoxDecoration(
                color: AppColors.iosGray.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Text(
                '$shelfNumber',
                style: const TextStyle(
                  color: AppColors.iosGray,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                  height: 1,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.iosGray,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        if (products.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              s.t('no_products'),
              style: const TextStyle(
                  color: AppColors.iosGray, fontSize: 13),
            ),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              // Figma uses 2 columns; on very wide tablets (>= 720 dp
              // available) bump to 3 so the right rail doesn't dominate.
              final cols = constraints.maxWidth >= 720 ? 3 : 2;
              return GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: cols,
                mainAxisSpacing: 18,
                crossAxisSpacing: 18,
                // Was 0.85 (215 × 253). Bumped to 0.895 to lop ≈5 % off
                // the card height so 3 rows × 2 cols of a single shelf
                // (6 cards) all fit in the 533 × 853 dp viewport at once.
                childAspectRatio: 0.895,
                children: [
                  for (final p in products) _ProductCard(product: p),
                ],
              );
            },
          ),
      ],
    );
  }
}

// ─────────────────────────── Card ───────────────────────────

class _ProductCard extends StatelessWidget {
  const _ProductCard({required this.product});

  final Product product;

  /// Adds one to the cart, but only if the board is currently healthy.
  /// We deliberately use the synchronous [BoardClient.isHealthy] flag
  /// here (not an awaited ping) — every tap should feel instant. The
  /// payment screen does the heavier "live ping" check before money
  /// changes hands; here it's enough to refuse the add if the
  /// recent-comm watchdog has already flagged the bus as broken.
  void _tryAdd(BuildContext context) {
    final svc = context.read<VendingService>();
    final board = context.read<BoardClient>();
    if (!board.isHealthy) {
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
          onTap: canAdd ? () => _tryAdd(context) : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ─── Image area (Figma: 200 dp of a 260 dp tall card ≈ 77 %).
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
                    // Counter pill on the left, blue plus on the right —
                    // mirrors the Figma "Selected" Card state. Counter
                    // pill is hidden until at least one is in the cart.
                    if (count > 0)
                      Positioned(
                        top: 12,
                        left: 12,
                        child: _CounterPill(
                          count: count,
                          onRemove: () => svc.removeOne(product.motorId),
                        ),
                      ),
                    Positioned(
                      top: 12,
                      right: 12,
                      child: _AddButton(
                        enabled: canAdd,
                        onTap: canAdd ? () => _tryAdd(context) : null,
                      ),
                    ),
                  ],
                ),
              ),
              // ─── Content area (name + price). Figma: 60-dp tall,
              // 16-dp horizontal padding, 8 top / 16 bottom.
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
                        '${product.priceTenge} ₸',
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

// ─────────────────────────── Shelf rail ───────────────────────────

class _ShelfSelector extends StatelessWidget {
  const _ShelfSelector({
    required this.selected,
    required this.onSelect,
    required this.shelfCount,
  });

  final int selected;
  final int shelfCount;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      // Tightened from 96 → 60. The pill itself is ~48 dp wide; we
      // give a 4 dp gutter on each side so it doesn't hug the right
      // edge of the screen. Bottom padding ≈ bottom-bar height so
      // "center" lands in the customer-visible area rather than
      // behind the action bar.
      width: 60,
      padding: const EdgeInsets.fromLTRB(0, 0, 10, 104),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.max,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text(
              'полки',
              style: TextStyle(
                color: AppColors.iosGray,
                fontSize: 11,
                fontWeight: FontWeight.w500,
                letterSpacing: -0.1,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: const Color(0xCCFFFFFF),
              borderRadius: BorderRadius.circular(28),
            ),
            padding:
                const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 1; i <= shelfCount; i++) ...[
                  _ShelfTab(
                    number: i,
                    active: i == selected,
                    onTap: () => onSelect(i),
                  ),
                  if (i < shelfCount)
                    Container(
                      width: 12,
                      height: 1,
                      margin: const EdgeInsets.symmetric(vertical: 12),
                      color: AppColors.iosGray.withValues(alpha: 0.3),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ShelfTab extends StatelessWidget {
  const _ShelfTab({
    required this.number,
    required this.active,
    required this.onTap,
  });

  final int number;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? AppColors.iosBlue : Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          // Was 56 — now 40, matches the slimmer rail.
          width: 40,
          height: 40,
          child: Center(
            child: Text(
              '$number',
              style: TextStyle(
                color: active ? Colors.white : AppColors.iosGray,
                fontSize: 17,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.2,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────── Bottom action ───────────────────────────

/// Persistent action bar pinned to the bottom of the catalog. Layout:
/// [round back button] [action pill] — both fixed sizes so the bar
/// height never jumps between empty / filled / pay states (the home
/// and cart screens share the same widgets to keep that promise).
class _BottomActionBar extends StatelessWidget {
  const _BottomActionBar();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final svc = context.watch<VendingService>();
    final hasCart = svc.cartCount > 0;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      // Solid bar with a gradient fade up top so scrolling cards
      // dissolve into the bar instead of peeking through the gap
      // between the back-button outline and the pill.
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
            RoundBackButton(
              // No meaningful "back" on the home root — placeholder for
              // a future screensaver / attract-loop screen.
              onTap: () {},
            ),
            const SizedBox(width: 12),
            ActionPill(
              icon: Icons.shopping_cart_outlined,
              label: s.t('cart'),
              value: hasCart
                  ? '${svc.cartCount} ${s.t('items_short')}'
                  : s.t('cart_empty').toLowerCase(),
              filled: hasCart,
              onTap: hasCart
                  ? () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const CartScreen()),
                      )
                  : null,
            ),
          ],
        ),
      ),
      ),
    );
  }
}

// ─────────────────────────── Corners + overlay ───────────────────────

class _MaintenanceOverlay extends StatefulWidget {
  const _MaintenanceOverlay({required this.onServiceTap});

  /// Forwarded to a small hidden hit-area in the top-right corner.
  /// Used to be the whole overlay — but customers were triggering
  /// 5-tap-to-service-mode by accident while complaining about the
  /// dead screen. Now only that corner counts.
  final VoidCallback onServiceTap;

  @override
  State<_MaintenanceOverlay> createState() => _MaintenanceOverlayState();
}

class _MaintenanceOverlayState extends State<_MaintenanceOverlay> {
  bool _requesting = false;
  String? _lastResult;

  /// Re-trigger the system "Allow USB access?" dialog. The most common
  /// reason this overlay shows up after a fresh install is that USB
  /// permission for the new signing identity hasn't been granted yet —
  /// kiosk mode masks the dialog, so the operator never sees it. Tapping
  /// this button forces it back into view.
  Future<void> _retry() async {
    if (_requesting) return;
    setState(() {
      _requesting = true;
      _lastResult = null;
    });
    final state = await KioskBridge.requestUsbPermission();
    if (!mounted) return;
    setState(() {
      _requesting = false;
      _lastResult = state;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    return Positioned.fill(
      // No outer GestureDetector — the overlay itself swallows hits via
      // its opaque Container colour, customers can't accidentally
      // dismiss / trigger anything by tapping the body. The 5-tap
      // service-entry shortcut lives in a 96-dp invisible square in
      // the top-right corner (sized so the operator can hit it
      // confidently with a finger).
      child: Stack(
        children: [
          Container(
            color: const Color(0xEB1C1C1E),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
            child: SingleChildScrollView(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.usb,
                      size: 84, color: AppColors.iosBlue),
                  const SizedBox(height: 20),
                  Text(
                    s.t('maintenance_title'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    s.t('maintenance_subtitle'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xCCFFFFFF),
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    constraints: const BoxConstraints(maxWidth: 460),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Step(
                          n: '1',
                          text: 'Воткните USB-кабель платы в планшет.',
                        ),
                        SizedBox(height: 8),
                        _Step(
                          n: '2',
                          text: 'Когда появится системный диалог '
                              '«Разрешить доступ к USB-устройству» — '
                              'поставьте галочку «Всегда» и нажмите OK.',
                        ),
                        SizedBox(height: 8),
                        _Step(
                          n: '3',
                          text: 'Подождите 5 секунд — приложение само '
                              'подключится к плате.',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: FilledButton.icon(
                      icon: _requesting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.refresh),
                      label: Text(_requesting
                          ? 'Запрашиваем...'
                          : 'Запросить доступ к USB'),
                      style: FilledButton.styleFrom(
                        padding:
                            const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: _requesting ? null : _retry,
                    ),
                  ),
                  if (_lastResult != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      switch (_lastResult) {
                        'granted' =>
                          '✓ Доступ уже выдан, подключаемся...',
                        'requested' =>
                          'Появится диалог Android — нажмите OK',
                        _ =>
                          'Плата не найдена. Проверьте кабель и питание.',
                      },
                      style: const TextStyle(
                        color: Color(0xCCFFFFFF),
                        fontSize: 12,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onServiceTap,
              child: const SizedBox(width: 96, height: 96),
            ),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.text});

  final String n;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: AppColors.iosBlue,
            borderRadius: BorderRadius.circular(11),
          ),
          alignment: Alignment.center,
          child: Text(
            n,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 12,
              height: 1.0,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: Color(0xEEFFFFFF),
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

class _MachidCorner extends StatelessWidget {
  const _MachidCorner({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final machid = context.watch<DeviceStorage>().machid;
    if (machid == null) return const SizedBox.shrink();
    return Positioned(
      right: 8,
      top: 8,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Text(
            '№$machid',
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
              color: Color.fromARGB(255, 162, 162, 175),
            ),
          ),
        ),
      ),
    );
  }
}

class _LangCorner extends StatelessWidget {
  const _LangCorner();

  // Storage / messages use ISO 'kk' for Kazakh — using 'kz' here makes
  // Strings.setLang() silently reject the call (containsKey check fails).
  static const _cycle = ['ru', 'kk', 'en'];

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final i = _cycle.indexOf(s.lang);
    final next = _cycle[(i + 1) % _cycle.length];
    final display = s.lang == 'kk' ? 'KZ' : s.lang.toUpperCase();
    return Positioned(
  // Sits under the machid badge (top: 8 + ≈26 dp of badge + 4 dp gap).
  right: 8,
  top: 40,
  child: GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => s.setLang(next),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 15),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.language,
              size: 14, color: Color.fromARGB(255, 175, 188, 197)),
          const SizedBox(width: 4),
          Text(
            display,
            style: const TextStyle(
              color: Color.fromARGB(255, 139, 151, 161),
              fontWeight: FontWeight.w900,
              fontSize: 11,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    ),
  ),
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
                    fontSize: 12, color: AppColors.iosGray)),
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
