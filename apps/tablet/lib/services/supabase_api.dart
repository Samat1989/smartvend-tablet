import 'dart:convert';

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

/// REST client for Supabase.
///
/// Reads (inventory / products / categories) use the anon key directly against
/// PostgREST. All WRITES and the pairing check go through SECURITY DEFINER RPCs
/// that validate (machid, secret) server-side and scope every write to the
/// calling machine's own rows — so the anon key alone can neither read another
/// machine's secret nor write on its behalf (see docs/security-audit-2026-06.md,
/// findings F1/F2/F4). The machine secret is provisioned at pairing and kept in
/// DeviceStorage; it is passed to each write RPC but never read back from the DB.
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

  /// POST a SECURITY DEFINER RPC with named params.
  Future<http.Response> _rpc(String fn, Map<String, dynamic> body) {
    return _client
        .post(_rest('rpc/$fn'), headers: _headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 10));
  }

  /// Extract a human-readable message from a PostgREST error body
  /// ({"message": "...", ...}); falls back to the raw body.
  static String _errMessage(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map && j['message'] is String) return j['message'] as String;
    } catch (_) {}
    return body;
  }

  static int _machidParam(String machid) => int.tryParse(machid) ?? -1;

  // ---------- pairing ----------

  /// Check that machid + secret match a row in micromarkets and that the row
  /// is of the right kind for this app, via the `verify_pairing` RPC.
  ///
  /// The RPC validates the secret server-side and returns only `kind` — the
  /// secret column is never sent to the client (closes audit F1). This app
  /// only handles `kind='vending'` machines; other kinds are rejected here
  /// with a clear message.
  ///
  /// Returns null on success, or a localised-style error string.
  Future<String?> verifyPairing(String machid, String secret) async {
    try {
      final resp = await _rpc('verify_pairing', {
        'p_machid': _machidParam(machid),
        'p_secret': secret.trim(),
      });
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final kind = (jsonDecode(resp.body) as String?)?.trim() ??
            'micromarket_tablet';
        if (kind != 'vending') {
          return 'Это не вендинг-аппарат (тип: $kind). '
              'Используйте приложение, соответствующее типу.';
        }
        return null;
      }
      final msg = _errMessage(resp.body);
      if (msg.contains('not found')) return 'Аппарат №$machid не найден';
      if (msg.contains('bad secret')) return 'Секрет не совпадает';
      return 'HTTP ${resp.statusCode}: ${resp.body}';
    } catch (e) {
      return 'Сеть: $e';
    }
  }

  // ---------- machine layout ----------

  /// Push the current machine layout JSON to Supabase via the
  /// `set_machine_layout` RPC, gated by the machine secret.
  Future<bool> pushMachineLayout({
    required String machid,
    required String secret,
    required String layoutJson,
  }) async {
    try {
      final resp = await _rpc('set_machine_layout', {
        'p_machid': _machidParam(machid),
        'p_secret': secret,
        'p_layout': jsonDecode(layoutJson),
      });
      if (resp.statusCode >= 200 && resp.statusCode < 300) return true;
      debugPrint('[pushMachineLayout] HTTP ${resp.statusCode} ${resp.body}');
      return false;
    } catch (e) {
      debugPrint('[pushMachineLayout] exception: $e');
      return false;
    }
  }

  // ---------- reads (anon SELECT) ----------

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

  /// Load the catalog of SKUs via the `list_catalog` RPC — scoped to the
  /// machine's owner (so one operator never sees another's products).
  /// Archived and draft rows are excluded by default so the picker stays clean.
  Future<FetchResult<List<CatalogProduct>>> fetchProducts({
    required String machid,
    required String secret,
    bool includeArchived = false,
    bool includeDrafts = false,
  }) async {
    try {
      final resp = await _rpc('list_catalog', {
        'p_machid': _machidParam(machid),
        'p_secret': secret,
        'p_include_archived': includeArchived,
        'p_include_drafts': includeDrafts,
      });
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return FetchResult.err('HTTP ${resp.statusCode}: ${resp.body}');
      }
      final list = jsonDecode(resp.body) as List;
      final products = <CatalogProduct>[
        for (final raw in list)
          CatalogProduct.fromJson(raw as Map<String, dynamic>),
      ];
      return FetchResult.ok(products);
    } catch (e) {
      return FetchResult.err('Сеть: $e');
    }
  }

  /// Load all available product categories (small, global to the project).
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

  /// Insert a draft `products` row from the tablet's manual-entry path
  /// (operator typed a name but didn't pick from the catalog), via the
  /// `create_draft_product` RPC. The new row is attributed to the machine's
  /// owner for later admin review. Returns the new product id, or null.
  Future<String?> createDraftProduct({
    required String machid,
    required String secret,
    required String name,
    String? imageUrl,
    String? emoji,
    String? categoryId,
  }) async {
    try {
      final resp = await _rpc('create_draft_product', {
        'p_machid': _machidParam(machid),
        'p_secret': secret,
        'p_name': name,
        'p_image_url': (imageUrl != null && imageUrl.isNotEmpty) ? imageUrl : null,
        'p_emoji': (emoji != null && emoji.isNotEmpty) ? emoji : null,
        'p_category_id': categoryId,
      });
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        debugPrint('[createDraftProduct] HTTP ${resp.statusCode} ${resp.body}');
        return null;
      }
      return jsonDecode(resp.body) as String?;
    } catch (e) {
      debugPrint('[createDraftProduct] exception: $e');
      return null;
    }
  }

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

  // ---------- sales (RPC, secret-scoped, server-priced) ----------

  /// Open a sale shell up-front (before the first motor turns). Returns the
  /// new server-generated sale id, or null on failure — caller falls back to
  /// [recordSale]. [expectedTotalTenge] is informational; the final amount is
  /// recomputed server-side by [completeSale].
  Future<String?> createSale({
    required String machid,
    required String secret,
    required String paymentId,
    required int expectedTotalTenge,
  }) async {
    try {
      final resp = await _rpc('open_sale', {
        'p_machid': _machidParam(machid),
        'p_secret': secret,
        'p_payment_id': paymentId,
        'p_expected_total': expectedTotalTenge,
      });
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        debugPrint('[createSale] open_sale failed: '
            'HTTP ${resp.statusCode} ${resp.body}');
        return null;
      }
      return jsonDecode(resp.body) as String?;
    } catch (e) {
      debugPrint('[createSale] exception: $e');
      return null;
    }
  }

  /// Persist a single dispense step against an existing sale via
  /// `record_sale_item`. The price is taken from the server's inventory row
  /// (not from the client), and stock is decremented atomically server-side
  /// on a successful dispense.
  Future<void> recordSaleItem({
    required String machid,
    required String secret,
    required String saleId,
    required DispenseStepResult step,
  }) async {
    final productId = step.product.id;
    if (productId == null) return;
    final dispensed = step.outcome == DispenseOutcome.ok;
    try {
      final resp = await _rpc('record_sale_item', {
        'p_machid': _machidParam(machid),
        'p_secret': secret,
        'p_sale_id': saleId,
        'p_product_id': productId,
        'p_qty': 1,
        'p_dispensed': dispensed,
        'p_result_code': (!dispensed) ? step.resultCode : null,
        'p_result_message':
            (!dispensed && step.message.isNotEmpty) ? step.message : null,
      });
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        debugPrint('[recordSaleItem] failed: '
            'HTTP ${resp.statusCode} ${resp.body}');
      }
    } catch (e) {
      debugPrint('[recordSaleItem] exception: $e');
    }
  }

  /// Close out a sale opened via [createSale]: marks it `completed` and the
  /// server recomputes `amount` as the sum of successfully-dispensed items.
  Future<void> completeSale({
    required String machid,
    required String secret,
    required String saleId,
  }) async {
    try {
      final resp = await _rpc('complete_sale', {
        'p_machid': _machidParam(machid),
        'p_secret': secret,
        'p_sale_id': saleId,
      });
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        debugPrint('[completeSale] failed: '
            'HTTP ${resp.statusCode} ${resp.body}');
      }
    } catch (e) {
      debugPrint('[completeSale] exception: $e');
    }
  }

  /// Fallback "record the whole sale at the end" path, used when the upfront
  /// [createSale] failed. Reuses the same secret-scoped RPCs (open → items →
  /// complete). Returns the new sale id, or null on error.
  Future<String?> recordSale({
    required String machid,
    required String secret,
    required int totalTenge,
    required String paymentId,
    required List<DispenseStepResult> items,
  }) async {
    final saleId = await createSale(
      machid: machid,
      secret: secret,
      paymentId: paymentId,
      expectedTotalTenge: totalTenge,
    );
    if (saleId == null) return null;
    for (final step in items) {
      await recordSaleItem(
          machid: machid, secret: secret, saleId: saleId, step: step);
    }
    await completeSale(machid: machid, secret: secret, saleId: saleId);
    return saleId;
  }

  // ---------- inventory editing (RPC, secret-scoped) ----------

  /// Insert (when [inventoryId] is null) or update an inventory row via the
  /// `upsert_inventory` RPC, scoped to [machid]. [catalogProductId] is the FK
  /// into `products` (required — DB has a NOT NULL constraint). Returns the
  /// row id on success, or null on failure.
  Future<String?> upsertProduct({
    String? inventoryId,
    required String catalogProductId,
    required String machid,
    required String secret,
    required int motorId,
    required String name,
    required int priceTenge,
    required int stock,
    required int motorType,
    required int curtainMode,
    String? imageUrl,
    String? emoji,
    String? categoryId,
  }) async {
    try {
      final resp = await _rpc('upsert_inventory', {
        'p_machid': _machidParam(machid),
        'p_secret': secret,
        'p_inventory_id': inventoryId,
        'p_product_id': catalogProductId,
        'p_motor_id': motorId,
        'p_name': name,
        'p_price': priceTenge,
        'p_stock': stock,
        'p_motor_type': motorType,
        'p_curtain_mode': curtainMode,
        'p_image_url': (imageUrl != null && imageUrl.isNotEmpty) ? imageUrl : null,
        'p_emoji': (emoji != null && emoji.isNotEmpty) ? emoji : null,
        'p_category_id': categoryId,
      });
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        debugPrint('[upsertProduct] failed: HTTP ${resp.statusCode} ${resp.body}');
        return null;
      }
      return jsonDecode(resp.body) as String?;
    } catch (e) {
      debugPrint('[upsertProduct] exception: $e');
      return null;
    }
  }

  /// PATCH only the wiring columns of an inventory row via the
  /// `update_inventory_wiring` RPC (null = leave as is).
  Future<bool> updateInventoryWiring({
    required String machid,
    required String secret,
    required String inventoryId,
    int? motorType,
    int? curtainMode,
  }) async {
    if (motorType == null && curtainMode == null) return true;
    try {
      final resp = await _rpc('update_inventory_wiring', {
        'p_machid': _machidParam(machid),
        'p_secret': secret,
        'p_inventory_id': inventoryId,
        'p_motor_type': motorType,
        'p_curtain_mode': curtainMode,
      });
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// Bulk curtain_mode update across [inventoryIds] via the
  /// `bulk_update_curtain` RPC. Returns the number of rows updated.
  Future<int> bulkUpdateCurtain({
    required String machid,
    required String secret,
    required List<String> inventoryIds,
    required int curtainMode,
  }) async {
    if (inventoryIds.isEmpty) return 0;
    try {
      final resp = await _rpc('bulk_update_curtain', {
        'p_machid': _machidParam(machid),
        'p_secret': secret,
        'p_inventory_ids': inventoryIds,
        'p_curtain_mode': curtainMode,
      });
      if (resp.statusCode < 200 || resp.statusCode >= 300) return 0;
      return (jsonDecode(resp.body) as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Bulk price update across [inventoryIds] via the `bulk_update_price` RPC.
  /// Returns the number of rows updated.
  Future<int> bulkUpdatePrice({
    required String machid,
    required String secret,
    required List<String> inventoryIds,
    required int priceTenge,
  }) async {
    if (inventoryIds.isEmpty) return 0;
    try {
      final resp = await _rpc('bulk_update_price', {
        'p_machid': _machidParam(machid),
        'p_secret': secret,
        'p_inventory_ids': inventoryIds,
        'p_price': priceTenge,
      });
      if (resp.statusCode < 200 || resp.statusCode >= 300) return 0;
      return (jsonDecode(resp.body) as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Delete one inventory row via the `delete_inventory` RPC, scoped to [machid].
  Future<bool> deleteProduct({
    required String machid,
    required String secret,
    required String inventoryId,
  }) async {
    try {
      final resp = await _rpc('delete_inventory', {
        'p_machid': _machidParam(machid),
        'p_secret': secret,
        'p_inventory_id': inventoryId,
      });
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (_) {
      return false;
    }
  }
}
