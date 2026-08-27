import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import '../board/board_client.dart';
import '../models/motor_layout.dart';
import '../models/product.dart';
import '../services/device_storage.dart';
import '../services/idle_service.dart';
import '../services/app_error.dart';
import '../services/strings.dart';
import '../services/vending_service.dart';
import '../theme.dart';
import '../widgets/action_pill.dart';
import '../widgets/product_card.dart';
import '../widgets/shelf_header.dart';
import '../widgets/lang_chip.dart';
import '../widgets/view_mode_toggle.dart';
import '../widgets/support_corner.dart';
import 'cart_screen.dart';
import 'screensaver_screen.dart';
import 'service_pin_screen.dart';

/// Space above the first row of product cards.
///
/// Lives here rather than inline because three places have to agree on it:
/// the list's own padding, the rail's scroll target, and the trigger line
/// that decides which shelf the rail highlights. The trigger comment drifted
/// out of sync with the padding twice before this constant existed.
/// Top inset of the catalog list.
///
/// Was 12. Now clears [ViewModeToggle], which floats above the list rather
/// than scrolling with it: 8 top + 52 pill + 4 gap. Cards still pass under
/// the pill as the customer scrolls — that is what its translucent white
/// background is for.
const double _kCatalogTopPadding = 64;

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

  // Hidden service entry: 12 quick taps on the language icon. The
  // threshold was 5 on the machid badge; bumped to 12 + moved to the
  // language icon because random customers fiddling with the badge
  // were accidentally landing on the PIN screen.
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
  // Idle delay before the attract loop is operator-set — a shop window
  // wants it after half a minute, a busy corridor not at all for ten.
  Duration get _screensaverAfter =>
      Duration(seconds: context.read<DeviceStorage>().screensaverDelaySec);
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
      svc.resetView();
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
      // Back to photos before the screensaver hides the catalog: the next
      // customer must find the cabinet showing pictures, not somebody
      // else's search for cell 14.
      svc.resetView();
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
  /// the viewport. The threshold is the catalog's top edge plus slack, so
  /// the rail flips about when a shelf header reaches the top of the list.
  /// The slack dominates — it is not tied to the exact padding, which has
  /// changed twice since this was written.
  void _onScroll() {
    const triggerDy = _kCatalogTopPadding + 80.0; // padding + slack
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
      ..removeWhere((t) => now.difference(t) > const Duration(seconds: 5));
    // 10 taps inside a rolling 5-second window. Was 12-in-3, which needs
    // four taps a second — hard to hit deliberately, let alone on a
    // resistive panel. 10-in-5 is still far past anything a curious
    // customer does by accident.
    if (_serviceTaps.length >= 10) {
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

    // Not Scrollable.ensureVisible(alignment: 0): that lands the shelf's top
    // edge exactly on the viewport's leading edge, which scrolls the list's
    // own top padding out of sight — picking a shelf made the grid sit flush
    // against the screen edge while free scrolling kept the gap. Compute the
    // same offset and back off by the padding so the two agree.
    final box = ctx.findRenderObject() as RenderBox?;
    final viewport = box == null ? null : RenderAbstractViewport.maybeOf(box);
    if (box == null || viewport == null || !_scrollController.hasClients) {
      await Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        alignment: 0,
      );
      return;
    }
    final position = _scrollController.position;
    final target = (viewport.getOffsetToReveal(box, 0).offset -
            _kCatalogTopPadding)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    await _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final board = context.watch<BoardClient>();
    // In debug builds, ignore board health so the UI / payment / mock
    // dispense flow can be exercised on a tablet with no M102 wired up.
    // Production builds keep the overlay so customers can't pay for
    // items the cabinet can't deliver.
    final boardDown = !kDebugMode && !board.isHealthy;
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // No header strip: the language chip and the support button both
            // live in the bottom-right corner now, so the grid starts at the
            // top of the screen.
            Expanded(
              child: Stack(
                // Force the Stack to take the full remaining height so the
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
                        onCaptionTap: _onServiceTap,
                        shelfCount:
                            context.watch<VendingService>().layout.isNotEmpty
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
                  // Above the catalog, left of the shelf rail. Listed after
                  // the list so cards scroll UNDER it, and before the
                  // maintenance curtain so a dead board hides it — with the
                  // cabinet not answering there is nothing to browse.
                  const Positioned(
                    top: 8,
                    left: 16,
                    child: ViewModeToggle(),
                  ),
                  if (boardDown)
                    _MaintenanceOverlay(onServiceTap: _onServiceTap),
                  // Bottom-RIGHT stack: language chip over the support
                  // button. Listed LAST on purpose — after the action bar so
                  // it sits over the bar's empty right side, and after the
                  // maintenance curtain because a dead board is exactly when
                  // a customer reaches for support, and burying the button
                  // under the "техническая проблема" screen would hide it at
                  // the one moment it matters most.
                  const Positioned(
                    right: 16,
                    bottom: 16,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      // Centred, not end-aligned: the chip is wider than the
                      // round support button, so aligning their right edges
                      // left the two visually off-axis. The Column takes the
                      // width of the wider child and the narrower one centres
                      // inside it.
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        LangChip(),
                        SizedBox(height: 14),
                        SupportCorner(),
                      ],
                    ),
                  ),
                  // Service entry used to live in an invisible 80×80 box
                  // pinned under the language chip. Being anchored to the
                  // top edge, it landed differently on every screen height —
                  // on some tablets in the dead space it was meant for, on
                  // others under the catalog. It's now the visible "полки"
                  // caption instead.
                ],
              ),
            ),
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
            return _ErrorView(error: svc.error);
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
              padding: const EdgeInsets.fromLTRB(
                  16, _kCatalogTopPadding, 8, 120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < shelves.length; i++) ...[
                    // The group itself is always built — its GlobalKey backs
                    // the right-rail scroll targets, and dropping it would
                    // shift every shelf number after it.
                    _ShelfGroup(
                      key: shelfKey(i + 1),
                      shelfNumber: i + 1,
                      label: shelves[i].label,
                      products: shelves[i].products,
                    ),
                    // …but skip the gap after a group that renders nothing,
                    // or an empty shelf leaves a double-height hole in the
                    // catalog once headers are off.
                    if (i < shelves.length - 1 &&
                        !(shelves[i].products.isEmpty &&
                            !context.watch<DeviceStorage>().showShelfLabels))
                      const SizedBox(height: 20),
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
    // Shelf header — hideable from «Витрина». On a cabinet whose shelves
    // aren't labelled it's noise between the rows of products.
    final showLabels = context.watch<DeviceStorage>().showShelfLabels;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showLabels) ...[
          ShelfHeader(shelfNumber: shelfNumber, label: label),
          const SizedBox(height: 8),
        ],
        if (products.isEmpty)
          // "Нет товаров" only makes sense under a header that says WHICH
          // shelf is empty. With headers off it's an orphan line in the
          // middle of the grid, so the whole group renders nothing.
          if (showLabels)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                s.t('no_products'),
                style: const TextStyle(
                    color: AppColors.iosGray, fontSize: 13),
              ),
            )
          else
            const SizedBox.shrink()
        else
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            // Operator-chosen, 2…5, set in «Витрина». Used to be derived
            // from the viewport width (2, or 3 above 720 dp), which gave
            // no say to the person who knows how many products the shelf
            // actually holds.
            crossAxisCount: context.watch<DeviceStorage>().gridColumns,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            // Was 0.85 (215 × 253). Bumped to 0.895 to lop ≈5 % off the
            // card height so 3 rows × 2 cols of a single shelf (6 cards)
            // all fit in the 533 × 853 dp viewport at once. The ratio is
            // constant across column counts, so cards keep their shape
            // and just get smaller as columns grow.
            childAspectRatio: 0.895,
            children: [
              for (final p in products) ProductCard(product: p),
            ],
          ),
      ],
    );
  }
}

// ─────────────────────────── Shelf rail ───────────────────────────

class _ShelfSelector extends StatelessWidget {
  const _ShelfSelector({
    required this.selected,
    required this.onSelect,
    required this.shelfCount,
    required this.onCaptionTap,
  });

  /// Hidden service-mode entry. The caption is a fixed, always-visible
  /// target that sits in the same place on every screen — unlike the old
  /// invisible box, which drifted with the viewport height.
  final VoidCallback onCaptionTap;

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
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onCaptionTap,
            child: Padding(
              // Vertical only. Side padding ate the little width the 60-dp
              // rail has, and the Kazakh «сөрелер» wrapped onto a second
              // line; the tap target the service entry needs comes from the
              // vertical insets instead.
              padding: const EdgeInsets.only(top: 8, bottom: 6),
              child: FittedBox(
                // Any caption stays on one line whatever the language —
                // it shrinks a little rather than wrapping or clipping.
                fit: BoxFit.scaleDown,
                child: Text(
                  context.watch<Strings>().t('shelves_caption'),
                  maxLines: 1,
                  softWrap: false,
                  style: const TextStyle(
                    color: AppColors.iosGray,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.1,
                  ),
                ),
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

/// Action bar pinned to the bottom of the catalog, shown only while the
/// cart has something in it. Holds just the centred action pill — the
/// catalog is the root screen, so there is nowhere to go back to. (The cart
/// screen keeps a RoundBackButton beside its pill, where "back" actually
/// means something.)
///
/// An empty cart renders nothing: the pill had a disabled «пусто» state that
/// occupied the bottom of every idle screen while saying that there is
/// nothing to tap. The list's bottom padding stays reserved either way, so
/// adding the first item reveals the bar over space the scroll already left
/// free instead of shifting the grid under the customer's finger.
class _BottomActionBar extends StatelessWidget {
  const _BottomActionBar();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final svc = context.watch<VendingService>();
    if (svc.cartCount == 0) {
      return const Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: SizedBox.shrink(),
      );
    }
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
            ActionPill(
              icon: Icons.shopping_cart_outlined,
              label: s.t('cart'),
              value: '${svc.cartCount} ${s.t('items_short')}',
              filled: true,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CartScreen()),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

// ─────────────────────────── Corners + overlay ───────────────────────

class _MaintenanceOverlay extends StatelessWidget {
  const _MaintenanceOverlay({required this.onServiceTap});

  /// Forwarded to a small hidden hit-area in the top-right corner.
  /// Used to be the whole overlay — but customers were triggering
  /// 5-tap-to-service-mode by accident while complaining about the
  /// dead screen. Now only that corner counts.
  final VoidCallback onServiceTap;

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
      //
      // Intentionally minimal — no retry button, no USB permission
      // instructions. The 800 ms init probe + USB-attach listener in
      // BoardClient handle the dialog automatically; surfacing it on
      // the customer-facing screen looks broken and invites curious
      // tapping. Operator path: top-right 5-tap → service mode →
      // Плата for diagnostics.
      child: Stack(
        children: [
          Container(
            color: const Color(0xEB1C1C1E),
            alignment: Alignment.center,
            padding: const EdgeInsets.all(40),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.build_circle,
                    size: 96, color: AppColors.iosOrange),
                const SizedBox(height: 24),
                Text(
                  s.t('maintenance_title'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  s.t('maintenance_subtitle'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xCCFFFFFF),
                    fontSize: 15,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onServiceTap,
              child: const SizedBox(width: 96, height: 96),
            ),
          ),
        ],
      ),
    );
  }
}

/// Right-aligned header strip: support badge + language switch.
///
/// These two used to float as `Positioned` children of the catalog Stack.
/// Pinned to the top-right they sat directly over the first shelf's cards —
/// on a 2-column layout the support chip covered a meaningful part of the
/// top-right product. Laying them out in the flow instead costs one strip of
/// height and gives the grid the whole area below, with nothing overlapping.

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error});

  /// Nullable because the service can be in the error state before it has
  /// classified anything; the headline alone still tells the customer the
  /// catalog did not load.
  final AppError? error;

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
            if (error != null)
              Text(s.t(error!.messageKey),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.iosGray)),
            const SizedBox(height: 8),
            // VendingService retries on a 5→30 s backoff while this
            // screen is up (boot races the tablet's network coming up) —
            // tell the customer/operator nothing needs to be pressed.
            Text(s.t('fetch_retrying'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.iosGray,
                    fontStyle: FontStyle.italic)),
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
