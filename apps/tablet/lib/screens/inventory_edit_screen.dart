import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/machine_layout.dart';
import '../models/product.dart';
import '../services/device_storage.dart';
import '../services/strings.dart';
import '../services/supabase_api.dart';
import '../services/vending_service.dart';
import '../theme.dart';
import 'layout_editor_screen.dart';
import 'product_edit_screen.dart';

/// Service-mode tool: vertical list of every slot in the operator-built
/// [MachineLayout], grouped by shelf. Each row exposes every per-slot
/// setting at a glance (name, price, stock, motor type, drop-sensor
/// mode) so the operator doesn't need to open the detail form just to
/// check what's configured.
///
/// Restocking uses an inline stepper (− N +) per row: taps only change a
/// local pending value (instant, no network), and every changed row is
/// written once — either via the app-bar "Save" button, or automatically
/// when the operator leaves the screen ([PopScope] + a [dispose] backstop
/// for any imperative pop). So a full restock costs one request per
/// *changed* slot, and un-saved edits can never be silently lost.
///
/// Products are still keyed in the catalog by single motor id
/// ([Product.motorId]), so we look each row's product up via the
/// slot's [Slot.primaryMotorId]. Twin/wide-spiral slots show every
/// motor id in the badge.
class InventoryEditScreen extends StatefulWidget {
  const InventoryEditScreen({super.key});

  @override
  State<InventoryEditScreen> createState() => _InventoryEditScreenState();
}

class _InventoryEditScreenState extends State<InventoryEditScreen> {
  final _api = SupabaseApi();

  /// Un-saved stock edits, keyed by inventory row id ([Product.id]).
  /// Value = the desired stock. An entry is removed when the stepper
  /// walks the value back to the DB stock (no longer dirty) or after a
  /// successful flush. Max stock per slot is capped at [_maxStock].
  final Map<String, int> _pending = {};
  static const int _maxStock = 99;

  bool _saving = false;

  // Captured in didChangeDependencies so [dispose] can flush without
  // touching an inherited widget after the element is deactivated.
  late VendingService _svc;
  late DeviceStorage _storage;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _svc = context.read<VendingService>();
    _storage = context.read<DeviceStorage>();
  }

  @override
  void dispose() {
    // Backstop for exits that bypass PopScope (imperative Navigator.pop /
    // popUntil). Fire-and-forget: the write goes through the long-lived
    // SupabaseApi / VendingService, so it completes even though this
    // widget is gone. No context / setState here — the element is dead.
    if (_pending.isNotEmpty) {
      final machid = _storage.machid;
      final secret = _storage.secret;
      if (machid != null && secret != null) {
        final snapshot = Map<String, int>.from(_pending);
        final svc = _svc;
        // ignore: unawaited_futures
        _writePending(snapshot, svc.catalog, machid, secret)
            .then((_) => svc.reload(silent: true));
      }
    }
    super.dispose();
  }

  /// Adjust a slot's pending stock by [delta], clamped to 0..[_maxStock].
  /// Removes the entry when the value returns to the DB stock so the
  /// dirty count stays accurate.
  void _bump(Product p, int delta) {
    final id = p.id;
    if (id == null || _saving) return;
    final current = _pending[id] ?? p.stock;
    final next = (current + delta).clamp(0, _maxStock);
    if (next == current) return;
    setState(() {
      if (next == p.stock) {
        _pending.remove(id);
      } else {
        _pending[id] = next;
      }
    });
  }

  /// Write every pending row via `upsert_inventory`, keeping all other
  /// fields as-is and only changing stock. Returns the ids that were
  /// persisted. Pure I/O — no state mutation, safe to call from dispose.
  Future<Set<String>> _writePending(
    Map<String, int> pending,
    List<Product> catalog,
    String machid,
    String secret,
  ) async {
    final byId = {
      for (final p in catalog)
        if (p.id != null) p.id!: p,
    };
    final done = <String>{};
    for (final entry in pending.entries) {
      final p = byId[entry.key];
      // Only rows already bound to a catalog SKU can be quick-restocked;
      // unmapped placeholders have no product_id (DB NOT NULL) and must
      // go through the full form first.
      if (p == null || p.catalogProductId == null) continue;
      final id = await _api.upsertProduct(
        inventoryId: p.id,
        catalogProductId: p.catalogProductId!,
        machid: machid,
        secret: secret,
        motorId: p.motorId,
        name: p.name,
        priceTenge: p.priceTenge,
        stock: entry.value,
        motorType: p.motorType,
        curtainMode: p.curtainMode,
        imageUrl: p.imageUrl,
        emoji: p.emoji,
        categoryId: p.categoryId,
      );
      if (id != null) done.add(entry.key);
    }
    return done;
  }

  /// Flush pending edits with UI feedback. Used by the "Save" button and
  /// before leaving the screen / opening the full form.
  Future<void> _saveNow({bool showToast = true}) async {
    if (_pending.isEmpty || _saving) return;
    final s = context.read<Strings>();
    final machid = _storage.machid;
    final secret = _storage.secret;
    if (machid == null || secret == null) return;

    setState(() => _saving = true);
    final snapshot = Map<String, int>.from(_pending);
    final done = await _writePending(snapshot, _svc.catalog, machid, secret);
    if (!mounted) return;
    _pending.removeWhere((k, _) => done.contains(k));
    await _svc.reload(silent: true);
    if (!mounted) return;
    setState(() => _saving = false);

    final failed = snapshot.length - done.length;
    if (showToast) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(failed == 0
            ? s.t('save_ok')
            : '${s.t('save_failed')} ($failed)'),
        backgroundColor: failed == 0 ? Colors.green : Colors.redAccent,
      ));
    }
  }

  /// Open the full per-slot form. Flush any pending stepper edits first so
  /// the form loads fresh DB values and its save can't clobber an
  /// un-flushed stock change on this slot.
  Future<void> _openForm(Slot slot, Product? product) async {
    final nav = Navigator.of(context);
    if (_pending.isNotEmpty) await _saveNow(showToast: false);
    if (!mounted) return;
    Product? existing = product;
    for (final p in _svc.catalog) {
      if (p.motorId == slot.primaryMotorId) {
        existing = p;
        break;
      }
    }
    await nav.push(
      MaterialPageRoute(
        builder: (_) => ProductEditScreen(
          motorId: slot.primaryMotorId,
          existing: existing,
        ),
      ),
    );
    if (mounted) await _svc.reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    return PopScope(
      canPop: _pending.isEmpty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        await _saveNow(showToast: false);
        if (mounted) nav.pop();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF5F6FA),
        appBar: AppBar(
          title: Text(s.t('inv_grid_title')),
          backgroundColor: Colors.white,
          foregroundColor: Colors.black87,
          elevation: 0,
          actions: [
            if (_pending.isNotEmpty)
              _saving
                  ? const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  : TextButton.icon(
                      onPressed: _saveNow,
                      icon: const Icon(Icons.save),
                      label: Text('${s.t('btn_save')} (${_pending.length})'),
                    ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: s.t('reload'),
              onPressed: _saving ? null : () => _svc.reload(),
            ),
          ],
        ),
        body: Consumer<VendingService>(
          builder: (context, svc, _) {
            if (svc.state == CatalogState.loading) {
              return const Center(child: CircularProgressIndicator());
            }
            final byMotor = {for (final p in svc.catalog) p.motorId: p};
            final layout = svc.layout;
            if (layout.isEmpty) {
              return const _EmptyLayoutHint();
            }
            return Column(
              children: [
                const _SensorModeHeader(),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                    itemCount: layout.shelves.length,
                    itemBuilder: (_, i) {
                      final shelf = layout.shelves[i];
                      return _ShelfBlock(
                        shelf: shelf,
                        byMotor: byMotor,
                        pending: _pending,
                        saving: _saving,
                        onBump: _bump,
                        onOpen: _openForm,
                      );
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

class _EmptyLayoutHint extends StatelessWidget {
  const _EmptyLayoutHint();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.grid_off, size: 56, color: Colors.grey.shade500),
            const SizedBox(height: 16),
            const Text(
              'Раскладка не настроена',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              'Сначала откройте редактор раскладки и выберите шаблон '
              '— после этого здесь появятся строки на каждый слот.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.dashboard_customize),
              label: const Text('Открыть редактор'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const LayoutEditorScreen(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShelfBlock extends StatelessWidget {
  const _ShelfBlock({
    required this.shelf,
    required this.byMotor,
    required this.pending,
    required this.saving,
    required this.onBump,
    required this.onOpen,
  });

  final Shelf shelf;
  final Map<int, Product> byMotor;
  final Map<String, int> pending;
  final bool saving;
  final void Function(Product product, int delta) onBump;
  final Future<void> Function(Slot slot, Product? product) onOpen;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Row(
              children: [
                Text(
                  shelf.label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '× ${shelf.slots.length}',
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.black54),
                ),
              ],
            ),
          ),
          if (shelf.slots.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Text(
                'нет слотов',
                style: TextStyle(fontSize: 12, color: Colors.black45),
              ),
            )
          else
            for (var i = 0; i < shelf.slots.length; i++) ...[
              Builder(builder: (_) {
                final slot = shelf.slots[i];
                final product = byMotor[slot.primaryMotorId];
                final pid = product?.id;
                return _ProductRow(
                  slot: slot,
                  product: product,
                  pendingStock: pid != null ? pending[pid] : null,
                  saving: saving,
                  onBump: onBump,
                  onOpen: onOpen,
                );
              }),
              if (i != shelf.slots.length - 1) const SizedBox(height: 8),
            ],
        ],
      ),
    );
  }
}

/// Global "real dispense" sensor mode, persisted in DeviceStorage. The
/// picker sits on top of the inventory list because that's where the
/// operator manages the warehouse / slots — it's conceptually a
/// per-machine warehouse setting, not a per-product one.
class _SensorModeHeader extends StatelessWidget {
  const _SensorModeHeader();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final storage = context.watch<DeviceStorage>();
    final mode = storage.dispenseSensorMode;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: const BoxDecoration(
        color: AppColors.surfaceContainerLowest,
        border: Border(
          bottom: BorderSide(
              color: AppColors.surfaceContainerHigh, width: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.sensors,
                  size: 18, color: AppColors.primary),
              const SizedBox(width: 8),
              Text(
                s.t('service_sensor_mode').toUpperCase(),
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                    color: AppColors.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: 0, label: Text(s.t('sensor_off'))),
              ButtonSegment(value: 1, label: Text(s.t('sensor_on'))),
            ],
            selected: {mode},
            onSelectionChanged: (set) =>
                storage.setDispenseSensorMode(set.first),
          ),
          const SizedBox(height: 6),
          Text(
            s.t('sensor_mode_hint'),
            style: const TextStyle(
                fontSize: 11,
                color: AppColors.onSurfaceVariant,
                height: 1.3),
          ),
        ],
      ),
    );
  }
}

class _ProductRow extends StatelessWidget {
  const _ProductRow({
    required this.slot,
    required this.product,
    required this.pendingStock,
    required this.saving,
    required this.onBump,
    required this.onOpen,
  });

  final Slot slot;
  final Product? product;

  /// Un-saved stock override for this row, or null when the row matches
  /// the DB (and for empty slots).
  final int? pendingStock;
  final bool saving;
  final void Function(Product product, int delta) onBump;
  final Future<void> Function(Slot slot, Product? product) onOpen;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final empty = product == null;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      elevation: 1,
      shadowColor: Colors.black12,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => onOpen(slot, product),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _slotBadge(slot),
              const SizedBox(width: 12),
              _thumb(),
              const SizedBox(width: 12),
              Expanded(child: _details(context, s)),
              const SizedBox(width: 4),
              // Mapped rows get the inline stepper; empty slots keep the
              // "add" affordance and open the full form on tap.
              if (empty)
                Icon(
                  Icons.add_circle_outline,
                  color: Colors.grey.shade400,
                  size: 22,
                )
              else
                _stepper(product!),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stepper(Product p) {
    final value = pendingStock ?? p.stock;
    final dirty = pendingStock != null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _stepButton(
          Icons.remove,
          (value <= 0 || saving) ? null : () => onBump(p, -1),
        ),
        Container(
          width: 40,
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$value',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: dirty
                      ? Colors.orange.shade800
                      : (value > 0 ? Colors.black87 : Colors.red),
                ),
              ),
              if (dirty)
                Container(
                  margin: const EdgeInsets.only(top: 2),
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: Colors.orange.shade700,
                    shape: BoxShape.circle,
                  ),
                ),
            ],
          ),
        ),
        _stepButton(
          Icons.add,
          (value >= _InventoryEditScreenState._maxStock || saving)
              ? null
              : () => onBump(p, 1),
        ),
      ],
    );
  }

  Widget _stepButton(IconData icon, VoidCallback? onTap) {
    final enabled = onTap != null;
    return Material(
      color: enabled ? Colors.indigo.shade50 : Colors.grey.shade100,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: 22,
            color: enabled ? Colors.indigo.shade700 : Colors.grey.shade400,
          ),
        ),
      ),
    );
  }

  Widget _slotBadge(Slot slot) {
    final motorsLabel = slot.motorIds.map((m) => 'M$m').join('+');
    return Container(
      width: 76,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      decoration: BoxDecoration(
        color: Colors.indigo.shade50,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            slot.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Colors.indigo.shade700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            motorsLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              color: Colors.grey.shade600,
              fontFamily: 'monospace',
            ),
          ),
          if (slot.isTwin) ...[
            const SizedBox(height: 2),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.iosOrange.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'TWIN',
                style: TextStyle(
                  color: AppColors.iosOrange,
                  fontSize: 8,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.0,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _thumb() {
    final p = product;
    if (p == null) {
      return Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(Icons.inbox, color: Colors.grey.shade400, size: 22),
      );
    }
    final url = p.imageUrl;
    if (url != null && url.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: CachedNetworkImage(
          imageUrl: url,
          width: 44,
          height: 44,
          fit: BoxFit.cover,
          placeholder: (_, _) => _emojiBox(p.emoji),
          errorWidget: (_, _, _) => _emojiBox(p.emoji),
        ),
      );
    }
    return _emojiBox(p.emoji);
  }

  Widget _emojiBox(String? emoji) => Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.indigo.shade50,
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: Text(emoji ?? '📦', style: const TextStyle(fontSize: 22)),
      );

  Widget _details(BuildContext context, Strings s) {
    final p = product;
    if (p == null) {
      return Text(
        s.t('inv_empty_slot'),
        style: TextStyle(
          color: Colors.grey.shade500,
          fontStyle: FontStyle.italic,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          p.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        // Price only — stock now lives in the inline stepper on the right.
        _chip(
          icon: Icons.payments_outlined,
          label: '${p.priceTenge} ${s.t('currency')}',
          color: Colors.indigo,
        ),
      ],
    );
  }

  Widget _chip({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
