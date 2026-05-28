import 'dart:async';

import 'package:flutter/foundation.dart' hide Category;

import '../board/board_client.dart';
import '../models/cart.dart';
import '../models/category.dart';
import '../models/machine_layout.dart';
import '../models/product.dart';
import 'device_storage.dart';
import 'supabase_api.dart';

enum CatalogState { loading, ready, error, unpaired }

/// Holds the catalog + the cart, and orchestrates dispense via [BoardClient].
///
/// Catalog is loaded from Supabase on construction (and on demand via
/// [reload]). Slots without a DB row remain absent from the catalog.
class VendingService extends ChangeNotifier {
  /// Catalog auto-refresh interval. Owner edits inventory/prices/stock
  /// from the Supabase dashboard or owner app; the tablet picks up changes
  /// within this window without manual reload. 60 s is conservative enough
  /// not to hammer Supabase (~1440 requests/day) and quick enough to feel
  /// near-instant for the operator.
  static const _autoRefreshInterval = Duration(seconds: 60);

  Timer? _autoRefreshTimer;

  VendingService({
    required this.board,
    required DeviceStorage storage,
    SupabaseApi? api,
  })  : _storage = storage,
        _api = api ?? SupabaseApi() {
    _layout = MachineLayout.decode(_storage.machineLayoutJson) ??
        MachineLayout.empty();
    _storage.addListener(_onStorageChanged);
    if (_storage.isPaired) {
      reload();
      _startAutoRefresh();
      // Push the locally-stored layout on every boot. Cheap (single
      // RPC), idempotent server-side, and ensures admin always shows
      // the same shelf shape the operator sees on the tablet without
      // requiring them to re-save in the editor.
      if (_layout.isNotEmpty) {
        unawaited(_pushLayoutToCloud(_layout.encode()));
      }
    } else {
      _state = CatalogState.unpaired;
    }
  }

  /// Operator-built machine layout (shelves + slots, including twin
  /// spirals). Empty until the operator configures it in service
  /// mode — callers should fall back to single-motor dispense when
  /// [layout.isEmpty] or when a product's motor_id doesn't map to
  /// any slot in the current layout.
  late MachineLayout _layout;
  MachineLayout get layout => _layout;

  /// Replace the layout, persist it, and notify listeners so the
  /// catalog re-renders against the new shelf/slot structure.
  ///
  /// Also pushes the layout to Supabase so admin (customer_web) can
  /// render the cabinet view the same way the operator sees it. Push
  /// is fire-and-forget — local persistence is the source of truth on
  /// the tablet, and the sync happens best-effort in the background.
  Future<void> setLayout(MachineLayout next) async {
    _layout = next;
    final encoded = next.encode();
    await _storage.setMachineLayoutJson(encoded);
    notifyListeners();

    unawaited(_pushLayoutToCloud(encoded));
  }

  Future<void> _pushLayoutToCloud(String layoutJson) async {
    final machid = _storage.machid;
    final secret = _storage.secret;
    if (machid == null || secret == null) return;
    await _api.pushMachineLayout(
      machid: machid,
      secret: secret,
      layoutJson: layoutJson,
    );
  }

  void _startAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = Timer.periodic(_autoRefreshInterval, (_) {
      // Skip cycles that would either disturb a customer mid-purchase or
      // overlap with a fetch that's already in flight. The next tick tries
      // again — silent retries are fine here, this is a background sync.
      if (!_storage.isPaired) return;
      if (_cart.isNotEmpty) return;
      if (_state == CatalogState.loading) return;
      reload(silent: true);
    });
  }

  void _stopAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
  }

  final BoardClient board;
  final DeviceStorage _storage;
  final SupabaseApi _api;

  final List<Product> _catalog = [];
  final List<Category> _categories = [];
  final List<CartItem> _cart = [];

  CatalogState _state = CatalogState.loading;
  String? _error;
  String? _paymentId;

  CatalogState get state => _state;
  String? get error => _error;
  List<Product> get catalog => List.unmodifiable(_catalog);
  List<Category> get categories => List.unmodifiable(_categories);
  List<CartItem> get cartItems => List.unmodifiable(_cart);
  String? get paymentId => _paymentId;

  int get cartCount => _cart.fold(0, (sum, i) => sum + i.quantity);
  int get cartTotalTenge => _cart.fold(0, (sum, i) => sum + i.totalTenge);
  bool get cartIsEmpty => _cart.isEmpty;

  void _onStorageChanged() {
    if (_storage.isPaired && _state == CatalogState.unpaired) {
      reload();
      _startAutoRefresh();
      if (_layout.isNotEmpty) {
        unawaited(_pushLayoutToCloud(_layout.encode()));
      }
    } else if (!_storage.isPaired && _state != CatalogState.unpaired) {
      _catalog.clear();
      _cart.clear();
      _state = CatalogState.unpaired;
      _stopAutoRefresh();
      notifyListeners();
    }
  }

  // ----- catalog -----

  /// Refresh catalog + categories from Supabase.
  ///
  /// [silent] = false (default): used for first load and explicit operator
  /// "reload" — switches to [CatalogState.loading] and shows a spinner.
  /// On error switches to [CatalogState.error] so the UI surfaces it.
  ///
  /// [silent] = true: used by the 60 s background timer. Skips the
  /// loading state transition so customers don't see the catalog blink
  /// to a spinner mid-browse. On a network error we keep the previously
  /// shown catalog and just try again on the next tick.
  Future<void> reload({bool silent = false}) async {
    if (!_storage.isPaired) return;
    if (!silent) {
      _state = CatalogState.loading;
      _error = null;
      notifyListeners();
    }
    // Categories list is global (not per-machid) — we fetch it in parallel
    // with inventory and surface only the latter's failure as a hard error.
    // If categories fail we just show no filter chips, which still lets
    // the operator browse and dispense.
    final results = await Future.wait([
      _api.fetchInventory(_storage.machid!),
      _api.fetchCategories(),
    ]);
    final invRes = results[0] as FetchResult<List<Product>>;
    final catRes = results[1] as FetchResult<List<Category>>;
    if (!invRes.isOk) {
      if (!silent) {
        _state = CatalogState.error;
        _error = invRes.error;
        notifyListeners();
      }
      // Silent path: keep showing the stale catalog. Better than blanking
      // it on a transient Wi-Fi blip.
      return;
    }
    // Hide sold-out items from the customer catalog — they still exist
    // in inventory (owner can refill from the dashboard) but shouldn't
    // appear in the shelf grid where they look tappable.
    _catalog
      ..clear()
      ..addAll(invRes.data!.where((p) => p.stock > 0));
    _catalog.sort((a, b) => a.shelfLabel.compareTo(b.shelfLabel));
    _categories
      ..clear()
      ..addAll(catRes.isOk ? catRes.data! : const []);
    _state = CatalogState.ready;
    notifyListeners();
  }

  void replaceProduct(Product updated) {
    final idx = _catalog.indexWhere((p) => p.motorId == updated.motorId);
    if (idx < 0) return;
    _catalog[idx] = updated;
    notifyListeners();
  }

  // ----- cart -----

  void addToCart(Product product) {
    if (!product.inStock) return;
    final existing = _cart.where((i) => i.product.motorId == product.motorId).toList();
    if (existing.isEmpty) {
      _cart.add(CartItem(product: product));
    } else {
      if (existing.first.quantity < product.stock) {
        existing.first.quantity++;
      }
    }
    notifyListeners();
  }

  void removeOne(int motorId) {
    final idx = _cart.indexWhere((i) => i.product.motorId == motorId);
    if (idx < 0) return;
    _cart[idx].quantity--;
    if (_cart[idx].quantity <= 0) _cart.removeAt(idx);
    notifyListeners();
  }

  void removeAll(int motorId) {
    _cart.removeWhere((i) => i.product.motorId == motorId);
    notifyListeners();
  }

  void clearCart() {
    _cart.clear();
    notifyListeners();
  }

  // ----- dispense -----

  /// Latch a successful payment so the dispense screen can record the sale.
  /// Cleared automatically when [dispenseAll] finishes.
  void beginPaidDispense({required String paymentId}) {
    _paymentId = paymentId;
  }

  /// Dispense everything in the cart, one motor at a time, sequentially.
  /// Yields per-item results so the UI can show progress.
  ///
  /// Sensor mode is global now: [DeviceStorage.dispenseSensorMode] applies
  /// to every motor regardless of the per-product `curtain_mode` column
  /// (kept in DB for legacy data but ignored at dispense time). Operators
  /// can switch the mode in service mode → «Режим выдачи».
  Stream<DispenseStepResult> dispenseAll() async* {
    final items = _cart.toList();
    final curtain = _storage.dispenseSensorMode;

    for (final item in items) {
      for (var n = 0; n < item.quantity; n++) {
        final r = await board.dispense(
          item.product.motorId,
          type: item.product.motorType,
          curtain: curtain,
        );
        if (r.success) {
          replaceProduct(item.product.copyWith(stock: item.product.stock - 1));
        }
        yield DispenseStepResult(
          product: item.product,
          outcome: r.success ? DispenseOutcome.ok : DispenseOutcome.failed,
          message: r.message,
          resultCode: r.finalStatus?.result,
        );
      }
    }

    _cart.clear();
    notifyListeners();
  }

  /// Take and clear the latched payment id (called by dispense screen after
  /// it has used the value for sale recording).
  String? consumePaymentId() {
    final id = _paymentId;
    _paymentId = null;
    return id;
  }

  @override
  void dispose() {
    _stopAutoRefresh();
    _storage.removeListener(_onStorageChanged);
    super.dispose();
  }
}
