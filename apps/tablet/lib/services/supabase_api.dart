import 'dart:convert';

// Hide Flutter foundation's `Category` (used for DiagnosticPropertiesBuilder)
// since we have our own Supabase model with the same name.
import 'package:flutter/foundation.dart' hide Category;
import 'package:http/http.dart' as http;

import 'app_error.dart';

import '../models/cart.dart';
import '../models/catalog_product.dart';
import '../models/category.dart';
import '../models/product.dart';

class SupabaseConfig {
  static const String url = 'https://cgvfhtvdtdjsyluhlcbq.supabase.co';
  static const String anonKey = 'sb_publishable_84RnaNCrFwxKicybxLGL2w_StEYpHnD';
}

/// Result of a paired-fetch attempt.
///
/// [error] is an [AppError], not a string: the UI renders it through
/// [Strings], so a status code or a response body cannot leak onto the
/// screen by someone printing what they caught.
class FetchResult<T> {
  final T? data;
  final AppError? error;
  FetchResult.ok(T this.data) : error = null;
  FetchResult.err(AppError this.error) : data = null;
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
/// Outcome of a claim attempt.
///
/// [occupied] is a flag rather than something the caller sniffs out of
/// [message]: the pairing screen only shows the text, but the heartbeat
/// *unpairs the tablet* on it, and deciding that by matching translated prose
/// would break silently the day the wording changes.
class ClaimOutcome {
  const ClaimOutcome.ok()
      : occupied = false,
        message = null;
  const ClaimOutcome.occupied(this.message) : occupied = true;
  const ClaimOutcome.failed(this.message) : occupied = false;

  /// Another tablet holds this machine. Distinct from a transport failure:
  /// only this one may cost the tablet its pairing.
  final bool occupied;

  /// [Strings] KEY for the reason, null on success. The caller resolves it —
  /// this layer has no language.
  final String? message;

  bool get ok => message == null;
}

class SupabaseApi {
  SupabaseApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Identity this tablet holds its machine with, set once at startup from
  /// [DeviceStorage.deviceId]. Sent as a header rather than an RPC parameter
  /// so the server-side check lives in one place (_assert_machine) instead of
  /// in every write function's signature.
  static String? deviceId;

  Map<String, String> get _headers => {
        'apikey': SupabaseConfig.anonKey,
        'Authorization': 'Bearer ${SupabaseConfig.anonKey}',
        'Content-Type': 'application/json',
        'x-device-id': ?deviceId,
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
  /// secret column is never sent to the client (closes audit F1).
  ///
  /// Two kinds are ours, because one app now drives both: `vending` (motors)
  /// and `micromarket_tablet` (a fridge with an electric lock). Which of the
  /// two a given machine behaves as is decided on site by the board protocol,
  /// not here — that setting is local and works without a network. This check
  /// only keeps the app off a machine it has no business running.
  ///
  /// `micromarket_static` stays rejected: that is the QR-sticker flow with no
  /// device at all, and a tablet paired to one would be claiming a machine
  /// nobody expects it on.
  ///
  /// Returns null on success, or a localised-style error string.
  static const _supportedKinds = {'vending', 'micromarket_tablet'};

  /// Returns null when the pair checks out, otherwise a [Strings] KEY.
  ///
  /// A key rather than a sentence: this reaches the pairing screen, which the
  /// installer may be running in any of the four languages. The last branch
  /// used to return `'HTTP ${resp.statusCode}: ${resp.body}'` — the RPC's raw
  /// response, straight onto the screen.
  Future<String?> verifyPairing(String machid, String secret) async {
    try {
      final resp = await _rpc('verify_pairing', {
        'p_machid': _machidParam(machid),
        'p_secret': secret.trim(),
      });
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        // Legacy rows predate the discriminator and default to
        // micromarket_tablet — which is now supported, so an absent value is
        // no longer a reason to refuse.
        final kind = (jsonDecode(resp.body) as String?)?.trim() ??
            'micromarket_tablet';
        if (!_supportedKinds.contains(kind)) {
          debugPrint('[verifyPairing] unsupported machine kind: $kind');
          return 'pair_err_kind';
        }
        return null;
      }
      final msg = _errMessage(resp.body);
      if (msg.contains('not found')) return 'pair_err_not_found';
      if (msg.contains('bad secret')) return 'pair_err_secret';
      final err = AppError.http(resp.statusCode, resp.body)
        ..log('verifyPairing');
      return err.messageKey;
    } catch (e) {
      return (AppError.from(e)..log('verifyPairing')).messageKey;
    }
  }

  // ---------- machine claim ----------

  /// Take this machine for [deviceId]. Returns null on success, or a
  /// ready-to-show reason when another tablet already holds it.
  ///
  /// Guards against the same machid running on two cabinets at once — which
  /// would have both writing the SAME inventory and sales, so a sale on one
  /// cabinet decrements the other's stock and the owner's revenue mixes two
  /// locations irreversibly.
  Future<ClaimOutcome> claimMachine({
    required String machid,
    required String secret,
    required String deviceId,
  }) async {
    try {
      final resp = await _rpc('claim_machine', {
        'p_machid': _machidParam(machid),
        'p_secret': secret.trim(),
        'p_device_id': deviceId,
      });
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final err = AppError.http(resp.statusCode, resp.body)
          ..log('claimMachine');
        return ClaimOutcome.failed(err.messageKey);
      }
      final body = jsonDecode(resp.body);
      if (body is Map && body['ok'] == true) return const ClaimOutcome.ok();
      // last_seen_at used to be spliced into the message shown on screen.
      // It belongs in the log: an installer needs "occupied, release it in
      // the panel", not a timestamp of the other tablet's last heartbeat.
      final seen = body is Map ? body['last_seen_at'] as String? : null;
      debugPrint('[claimMachine] occupied, last seen: $seen');
      return const ClaimOutcome.occupied('pair_err_occupied');
    } catch (e) {
      return ClaimOutcome.failed(
          (AppError.from(e)..log('claimMachine')).messageKey);
    }
  }

  /// Give the machine up so another tablet can take it. Best-effort: the
  /// operator is signing out either way, and the owner panel can always
  /// unbind if this call didn't get through.
  Future<void> releaseMachine({
    required String machid,
    required String secret,
    required String deviceId,
  }) async {
    try {
      await _rpc('release_machine', {
        'p_machid': _machidParam(machid),
        'p_secret': secret.trim(),
        'p_device_id': deviceId,
      });
    } catch (_) {}
  }

  // ---------- heartbeat ----------

  /// Report "this machine is alive" plus whether its control board is
  /// answering, so the owner panel can tell an off-line kiosk from one that
  /// is on-line with a dead board — different faults, different call-outs.
  ///
  /// Fire-and-forget by design: a failed heartbeat means the machine is
  /// off-line, which is exactly what the absence of the beat already says.
  /// Nothing upstream should change behaviour because of it, and it must
  /// never surface an error to a customer standing at the cabinet.
  /// Returns the server's verdict: `{claim, layout}`. `claim` is 'lost' when
  /// another tablet holds this machine — the caller must stop working.
  /// `layout` is 'ok' / 'push' / 'stale'. Null when the beat didn't land.
  Future<Map<String, dynamic>?> ping({
    required String machid,
    required String secret,
    bool? boardOk,
    String? appVersion,
    String? layoutHash,
    String? layoutSavedAt,
    String? deviceId,
    String? terNumber,
  }) async {
    try {
      final resp = await _rpc('device_ping', {
        'p_machid': _machidParam(machid),
        'p_secret': secret.trim(),
        'p_board_ok': boardOk,
        'p_app_version': appVersion,
        'p_layout_hash': layoutHash,
        'p_layout_at': layoutSavedAt,
        'p_device_id': deviceId,
        // Reported, never read back: the panel needs to show which rail a
        // cabinet pays on, but the tablet is what decides it.
        'p_ter_number': terNumber,
      });
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      return jsonDecode(resp.body) as Map<String, dynamic>?;
    } catch (_) {
      // Offline / DNS / timeout — nothing to do, the missing beat is the signal.
      return null;
    }
  }

  // ---------- machine layout ----------

  /// Push the current machine layout JSON to Supabase via the
  /// `set_machine_layout` RPC, gated by the machine secret.
  Future<bool> pushMachineLayout({
    required String machid,
    required String secret,
    required String layoutJson,
    String? hash,
  }) async {
    try {
      final resp = await _rpc('set_machine_layout', {
        'p_machid': _machidParam(machid),
        'p_secret': secret,
        'p_layout': jsonDecode(layoutJson),
        // Hashed over OUR encoding — the server stores it verbatim and never
        // recomputes it, because jsonb reorders keys and would never match.
        'p_hash': hash,
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
        return FetchResult.err(AppError.http(r.statusCode, r.body));
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
      return FetchResult.err(AppError.from(e));
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
        return FetchResult.err(AppError.http(resp.statusCode, resp.body));
      }
      final list = jsonDecode(resp.body) as List;
      final products = <CatalogProduct>[
        for (final raw in list)
          CatalogProduct.fromJson(raw as Map<String, dynamic>),
      ];
      return FetchResult.ok(products);
    } catch (e) {
      return FetchResult.err(AppError.from(e));
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
        return FetchResult.err(AppError.http(r.statusCode, r.body));
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
      return FetchResult.err(AppError.from(e));
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
