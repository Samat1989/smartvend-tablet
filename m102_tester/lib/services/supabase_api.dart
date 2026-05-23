import 'dart:convert';
import 'dart:math';

// Hide Flutter foundation's `Category` (used for DiagnosticPropertiesBuilder)
// since we have our own Supabase model with the same name.
import 'package:flutter/foundation.dart' hide Category;
import 'package:http/http.dart' as http;

import '../models/cart.dart';
import '../models/catalog_product.dart';
import '../models/category.dart';
import '../models/product.dart';

class SupabaseConfig {
  static const String url = 'https://cgvfhtvdtdjsyluhlcbq.supabase.co';
  static const String anonKey = 'sb_publishable_84RnaNCrFwxKicybxLGL2w_StEYpHnD';
}

/// Result of a paired-fetch attempt.
class FetchResult<T> {
  final T? data;
  final String? error;
  FetchResult.ok(T this.data) : error = null;
  FetchResult.err(String this.error) : data = null;
  bool get isOk => error == null;
}

/// REST client for Supabase. Uses anon key (RLS allows anon SELECT on
/// inventory/micromarkets and INSERT on sales/sales_items per project policy).
class SupabaseApi {
  SupabaseApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Map<String, String> get _headers => {
        'apikey': SupabaseConfig.anonKey,
        'Authorization': 'Bearer ${SupabaseConfig.anonKey}',
        'Content-Type': 'application/json',
      };

  Uri _rest(String path, [Map<String, String>? query]) =>
      Uri.parse('${SupabaseConfig.url}/rest/v1/$path').replace(queryParameters: query);

  // ---------- pairing ----------

  /// Check that machid + secret pair matches a row in micromarkets and
  /// that the row is of the right kind for this app.
  ///
  /// This app only handles `kind='vending'` machines — staffed and
  /// static-QR micromarkets are served by other apps. Pairing the wrong
  /// kind would silently succeed at the credential layer and then fail
  /// later (no products with motor_id, no dispense possible), so we
  /// reject it here with a clear message.
  ///
  /// Returns null on success, or a localised-style error string.
  Future<String?> verifyPairing(String machid, String secret) async {
    try {
      final r = await _client.get(
        _rest('micromarkets',
            {'id': 'eq.$machid', 'select': 'id,secret,kind', 'limit': '1'}),
        headers: _headers,
      ).timeout(const Duration(seconds: 10));
      if (r.statusCode < 200 || r.statusCode >= 300) {
        return 'HTTP ${r.statusCode}: ${r.body}';
      }
      final list = jsonDecode(r.body) as List;
      if (list.isEmpty) return 'Аппарат №$machid не найден';
      final row = list.first as Map<String, dynamic>;
      final dbSecret = (row['secret'] as String?)?.trim();
      if (dbSecret == null || dbSecret.isEmpty) {
        return 'Секрет аппарата не задан в базе';
      }
      if (dbSecret != secret.trim()) return 'Секрет не совпадает';
      // Older databases without the kind column return null — treat as the
      // legacy default (micromarket_tablet), still rejected here.
      final kind = row['kind']?.toString() ?? 'micromarket_tablet';
      if (kind != 'vending') {
        return 'Это не вендинг-аппарат (тип: $kind). '
            'Используйте приложение, соответствующее типу.';
      }
      return null;
    } catch (e) {
      return 'Сеть: $e';
    }
  }

  // ---------- machine layout ----------

  /// Push the current [MachineLayout] JSON to Supabase via the
  /// `set_machine_layout` RPC. Gated by the machine secret (same one
  /// used in [verifyPairing]) so anon tablets can write only their
  /// own layout. Admin reads `micromarkets.layout_json` to render the
  /// same cabinet view the operator sees on-device.
  Future<bool> pushMachineLayout({
    required String machid,
    required String secret,
    required String layoutJson,
  }) async {
    try {
      final resp = await _client.post(
        _rest('rpc/set_machine_layout'),
        headers: _headers,
        body: jsonEncode({
          'p_machid': int.tryParse(machid) ?? machid,
          'p_secret': secret,
          'p_layout': jsonDecode(layoutJson),
        }),
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode >= 200 && resp.statusCode < 300) return true;
      debugPrint('[pushMachineLayout] HTTP ${resp.statusCode} ${resp.body}');
      return false;
    } catch (e) {
      debugPrint('[pushMachineLayout] exception: $e');
      return false;
    }
  }

  // ---------- inventory ----------

  /// Load all inventory rows for [machid]. Maps to [Product] objects keyed
  /// by motor_id. Slots without a DB row stay as placeholders.
  Future<FetchResult<List<Product>>> fetchInventory(String machid) async {
    try {
      final r = await _client.get(
        _rest('inventory', {
          'micromarket_id': 'eq.$machid',
          'select':
              'id,name,price,stock,image_url,motor_id,motor_type,curtain_mode,emoji,category_id,product_id',
        }),
        headers: _headers,
      ).timeout(const Duration(seconds: 15));
      if (r.statusCode < 200 || r.statusCode >= 300) {
        return FetchResult.err('HTTP ${r.statusCode}: ${r.body}');
      }
      final list = jsonDecode(r.body) as List;
      final products = <Product>[];
      for (final raw in list) {
        final row = raw as Map<String, dynamic>;
        final motorId = _asInt(row['motor_id']);
        if (motorId == null) continue; // unmapped row, skip
        final priceTenge = _asInt(row['price']) ?? 0;
        products.add(Product(
          id: row['id']?.toString(),
          motorId: motorId,
          shelfLabel: _shelfFromMotor(motorId),
          name: row['name']?.toString() ?? 'Без названия',
          priceTenge: priceTenge,
          motorType: _asInt(row['motor_type']) ?? 2,
          curtainMode: _asInt(row['curtain_mode']) ?? 0,
          stock: _asInt(row['stock']) ?? 0,
          emoji: row['emoji']?.toString(),
          imageUrl: row['image_url']?.toString(),
          categoryId: row['category_id']?.toString(),
          catalogProductId: row['product_id']?.toString(),
        ));
      }
      return FetchResult.ok(products);
    } catch (e) {
      return FetchResult.err('Сеть: $e');
    }
  }

  /// Load the catalog of SKUs (`products` table). Used by the tablet's
  /// "Выбрать из каталога" picker — operators don't type names by hand
  /// when a matching product already exists. Archived and draft rows
  /// are excluded by default so the picker stays clean.
  Future<FetchResult<List<CatalogProduct>>> fetchProducts({
    bool includeArchived = false,
    bool includeDrafts = false,
  }) async {
    try {
      final query = <String, String>{
        'select':
            'id,name,image_url,emoji,category_id,volume_ml,description,is_draft,is_archived',
        'order': 'name.asc',
      };
      // PostgREST: combine filters via and=(...) so both can be active.
      final filters = <String>[];
      if (!includeArchived) filters.add('is_archived.eq.false');
      if (!includeDrafts) filters.add('is_draft.eq.false');
      if (filters.isNotEmpty) {
        query['and'] = '(${filters.join(',')})';
      }
      final r = await _client.get(
        _rest('products', query),
        headers: _headers,
      ).timeout(const Duration(seconds: 15));
      if (r.statusCode < 200 || r.statusCode >= 300) {
        return FetchResult.err('HTTP ${r.statusCode}: ${r.body}');
      }
      final list = jsonDecode(r.body) as List;
      final products = <CatalogProduct>[
        for (final raw in list)
          CatalogProduct.fromJson(raw as Map<String, dynamic>),
      ];
      return FetchResult.ok(products);
    } catch (e) {
      return FetchResult.err('Сеть: $e');
    }
  }

  /// Insert a draft `products` row from the tablet's manual-entry path
  /// (operator typed a name but didn't pick from the catalog). RLS
  /// allows this only with `is_draft=true`, so admin can later review
  /// and promote it from customer_web.
  ///
  /// Returns the new product id, or null on failure.
  Future<String?> createDraftProduct({
    required String name,
    String? imageUrl,
    String? emoji,
    String? categoryId,
  }) async {
    try {
      final resp = await _client.post(
        _rest('products'),
        headers: {..._headers, 'Prefer': 'return=representation'},
        body: jsonEncode({
          'name': name,
          if (imageUrl != null && imageUrl.isNotEmpty) 'image_url': imageUrl,
          if (emoji != null && emoji.isNotEmpty) 'emoji': emoji,
          'category_id': ?categoryId,
          'is_draft': true,
        }),
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        debugPrint('[createDraftProduct] HTTP ${resp.statusCode} ${resp.body}');
        return null;
      }
      final list = jsonDecode(resp.body);
      if (list is List && list.isNotEmpty) {
        return list.first['id'] as String?;
      }
      return null;
    } catch (e) {
      debugPrint('[createDraftProduct] exception: $e');
      return null;
    }
  }

  /// Load all available product categories. The list is small (~10 rows)
  /// and global to the Supabase project — not per-machid — so we fetch
  /// it once on app start alongside the inventory.
  Future<FetchResult<List<Category>>> fetchCategories() async {
    try {
      final r = await _client.get(
        _rest('categories', {
          'select': 'id,name_ru,name_kz,name_en',
          'order': 'name_ru.asc',
        }),
        headers: _headers,
      ).timeout(const Duration(seconds: 10));
      if (r.statusCode < 200 || r.statusCode >= 300) {
        return FetchResult.err('HTTP ${r.statusCode}: ${r.body}');
      }
      final list = jsonDecode(r.body) as List;
      final cats = <Category>[];
      for (final raw in list) {
        final row = raw as Map<String, dynamic>;
        final id = row['id']?.toString();
        if (id == null) continue;
        cats.add(Category(
          id: id,
          nameRu: row['name_ru']?.toString() ?? '',
          nameKk: row['name_kz']?.toString() ?? '',
          nameEn: row['name_en']?.toString() ?? '',
        ));
      }
      return FetchResult.ok(cats);
    } catch (e) {
      return FetchResult.err('Сеть: $e');
    }
  }

  static final _rng = Random.secure();

  /// Generate a RFC 4122 v4 UUID. Used for sale / sales_item ids so we
  /// don't have to read PostgREST `Prefer: return=representation` (anon
  /// can INSERT but not SELECT under the project's RLS).
  static String _uuidV4() {
    final b = List<int>.generate(16, (_) => _rng.nextInt(256));
    b[6] = (b[6] & 0x0F) | 0x40; // version 4
    b[8] = (b[8] & 0x3F) | 0x80; // variant 10xx
    String h(int x) => x.toRadixString(16).padLeft(2, '0');
    final s = b.map(h).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}'
        '-${s.substring(16, 20)}-${s.substring(20, 32)}';
  }

  /// Coerce a JSON value (which Postgres/PostgREST may return as int, double,
  /// or string depending on the column type) to a Dart int. Returns null
  /// if the value can't be parsed.
  static int? _asInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.round();
    if (v is String) {
      final parsed = num.tryParse(v);
      return parsed?.round();
    }
    return null;
  }

  static String _shelfFromMotor(int motorId) {
    final row = 10 - motorId ~/ 10;
    final col = 10 - motorId % 10;
    final n = (row - 1) * 10 + col;
    return n.toString().padLeft(3, '0');
  }

  // ---------- sales ----------

  /// Insert a sale + its items. Returns the new sale id, or null on error.
  /// [items] should already be filtered to items the customer paid for —
  /// failed dispenses still get recorded so owner sees them.
  Future<String?> recordSale({
    required String machid,
    required int totalTenge,
    required String paymentId,
    required List<DispenseStepResult> items,
  }) async {
    try {
      // Generate the sale id client-side. The micromarket project's RLS
      // grants anon INSERT on `sales` but not SELECT — so a normal
      // `Prefer: return=representation` would yield an empty body and we'd
      // never find out our own row id. Generating it here removes that
      // dependency: the row is inserted with a known id we can immediately
      // use for `sales_items.sale_id`.
      final saleId = _uuidV4();
      final saleResp = await _client.post(
        _rest('sales'),
        headers: {..._headers, 'Prefer': 'return=minimal'},
        body: jsonEncode({
          'id': saleId,
          'micromarket_id': int.tryParse(machid) ?? machid,
          'amount': totalTenge,
          'status': 'completed',
          'payment_id': paymentId,
        }),
      ).timeout(const Duration(seconds: 10));
      if (saleResp.statusCode < 200 || saleResp.statusCode >= 300) {
        debugPrint('[recordSale] sales insert failed: '
            'HTTP ${saleResp.statusCode} ${saleResp.body}');
        return null;
      }

      // Aggregate quantities so we don't decrement twice when the same
      // motor is dispensed multiple times in one sale.
      final dispensedByProduct = <String, int>{};
      final productByDispensed = <String, DispenseStepResult>{};
      for (final r in items) {
        final productId = r.product.id;
        if (productId == null) continue;
        final itemResp = await _client.post(
          _rest('sales_items'),
          headers: {..._headers, 'Prefer': 'return=minimal'},
          body: jsonEncode({
            'id': _uuidV4(),
            'sale_id': saleId,
            'product_id': productId,
            'price': r.product.priceTenge,
            'quantity': 1,
            'dispensed': r.success,
          }),
        ).timeout(const Duration(seconds: 8));
        if (itemResp.statusCode < 200 || itemResp.statusCode >= 300) {
          debugPrint('[recordSale] sales_items insert failed: '
              'HTTP ${itemResp.statusCode} ${itemResp.body}');
        }
        if (r.success) {
          dispensedByProduct[productId] =
              (dispensedByProduct[productId] ?? 0) + 1;
          productByDispensed[productId] = r;
        }
      }

      // Decrement stock per product. We use a direct PATCH (not the
      // `decrement_stock` RPC) because the anon-write RLS we added covers
      // this path and the RPC may not be installed everywhere yet.
      for (final entry in dispensedByProduct.entries) {
        final productId = entry.key;
        final qty = entry.value;
        final currentStock = productByDispensed[productId]!.product.stock;
        final newStock = (currentStock - qty).clamp(0, 1 << 31);
        final patchResp = await _client.patch(
          _rest('inventory', {'id': 'eq.$productId'}),
          headers: _headers,
          body: jsonEncode({'stock': newStock}),
        ).timeout(const Duration(seconds: 8));
        if (patchResp.statusCode < 200 || patchResp.statusCode >= 300) {
          debugPrint('[recordSale] stock PATCH failed for $productId: '
              'HTTP ${patchResp.statusCode} ${patchResp.body}');
        }
      }
      return saleId;
    } catch (e) {
      debugPrint('[recordSale] exception: $e');
      return null;
    }
  }

  // ---------- inventory editing ----------

  /// Insert (when [inventoryId] is null) or update an inventory row.
  /// Returns the row id on success, or null on failure.
  ///
  /// [catalogProductId] is the FK into `products` — required for new
  /// inserts (the DB has a NOT NULL constraint). Callers who let the
  /// operator type a product name freehand should first invoke
  /// [createDraftProduct] and pass the returned id here.
  ///
  /// `name`, `imageUrl`, `emoji`, `categoryId` are still written to
  /// `inventory` for backwards-compat with the customer_web build that
  /// hasn't been migrated to read from `products` yet. They mirror the
  /// fields on the linked product so the catalog stays the source of
  /// truth.
  Future<String?> upsertProduct({
    String? inventoryId,
    required String catalogProductId,
    required String machid,
    required int motorId,
    required String name,
    required int priceTenge,
    required int stock,
    required int motorType,
    required int curtainMode,
    String? imageUrl,
    String? emoji,
    // `null` = "Без категории" (clear FK), non-null = set/replace it.
    // We always include the key so PATCH can clear an existing value.
    String? categoryId,
  }) async {
    final body = <String, dynamic>{
      'micromarket_id': int.tryParse(machid) ?? machid,
      'motor_id': motorId,
      'product_id': catalogProductId,
      'name': name,
      'price': priceTenge,
      'stock': stock,
      'motor_type': motorType,
      'curtain_mode': curtainMode,
      'category_id': categoryId, // include so PATCH can null-it-out
      if (imageUrl != null && imageUrl.isNotEmpty) 'image_url': imageUrl,
      if (imageUrl != null && imageUrl.isEmpty) 'image_url': null,
      if (emoji != null && emoji.isNotEmpty) 'emoji': emoji,
      if (emoji != null && emoji.isEmpty) 'emoji': null,
    };
    try {
      final http.Response resp;
      if (inventoryId == null) {
        resp = await _client.post(
          _rest('inventory'),
          headers: {..._headers, 'Prefer': 'return=representation'},
          body: jsonEncode(body),
        ).timeout(const Duration(seconds: 10));
      } else {
        resp = await _client.patch(
          _rest('inventory', {'id': 'eq.$inventoryId'}),
          headers: {..._headers, 'Prefer': 'return=representation'},
          body: jsonEncode(body),
        ).timeout(const Duration(seconds: 10));
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final list = jsonDecode(resp.body);
      if (list is List && list.isNotEmpty) {
        return list.first['id'] as String?;
      }
      return inventoryId;
    } catch (_) {
      return null;
    }
  }

  /// PATCH only the wiring-related columns of an inventory row.
  /// Used by the motor-setup screen so the operator can change motor
  /// type / drop-sensor mode per slot without going through the full
  /// product editor.
  Future<bool> updateInventoryWiring({
    required String inventoryId,
    int? motorType,
    int? curtainMode,
  }) async {
    final body = <String, dynamic>{
      'motor_type': ?motorType,
      'curtain_mode': ?curtainMode,
    };
    if (body.isEmpty) return true;
    try {
      final resp = await _client.patch(
        _rest('inventory', {'id': 'eq.$inventoryId'}),
        headers: _headers,
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 8));
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// Bulk update of curtain_mode across many inventory rows. Returns
  /// the number of rows that succeeded (best-effort — the server
  /// commits each PATCH independently). Used by the "apply to all"
  /// affordance in motor setup.
  Future<int> bulkUpdateCurtain({
    required List<String> inventoryIds,
    required int curtainMode,
  }) async {
    var ok = 0;
    for (final id in inventoryIds) {
      if (await updateInventoryWiring(inventoryId: id, curtainMode: curtainMode)) {
        ok++;
      }
    }
    return ok;
  }

  /// Bulk price update across many inventory rows. Used by the
  /// "apply price to other slots" affordance in the product editor.
  Future<int> bulkUpdatePrice({
    required List<String> inventoryIds,
    required int priceTenge,
  }) async {
    var ok = 0;
    for (final id in inventoryIds) {
      try {
        final resp = await _client.patch(
          _rest('inventory', {'id': 'eq.$id'}),
          headers: _headers,
          body: jsonEncode({'price': priceTenge}),
        ).timeout(const Duration(seconds: 8));
        if (resp.statusCode >= 200 && resp.statusCode < 300) ok++;
      } catch (_) {}
    }
    return ok;
  }

  /// Delete a product row by id.
  Future<bool> deleteProduct(String productId) async {
    try {
      final resp = await _client.delete(
        _rest('inventory', {'id': 'eq.$productId'}),
        headers: _headers,
      ).timeout(const Duration(seconds: 10));
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

}
