import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/catalog_product.dart';
import '../models/machine_layout.dart';
import '../models/product.dart';
import '../services/device_storage.dart';
import '../services/strings.dart';
import '../services/supabase_api.dart';
import '../services/vending_service.dart';

/// Form for binding / editing the product at a single motor slot.
/// Supplies a "Test motor" button so the operator can verify the wiring
/// before committing the row.
class ProductEditScreen extends StatefulWidget {
  const ProductEditScreen({
    super.key,
    required this.motorId,
    this.existing,
  });

  final int motorId;
  final Product? existing;

  @override
  State<ProductEditScreen> createState() => _ProductEditScreenState();
}

class _ProductEditScreenState extends State<ProductEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _stockCtrl = TextEditingController();
  final _emojiCtrl = TextEditingController();
  final _imageCtrl = TextEditingController();
  final _api = SupabaseApi();

  int _motorType = 2;
  int _curtain = 0;
  String? _categoryId;
  bool _saving = false;

  /// FK into `products`. Set when the operator picks from the catalog,
  /// inherited from the existing inventory row if editing, or `null`
  /// when the operator is typing a new SKU freehand (we create a draft
  /// product row on save).
  String? _catalogProductId;

  /// Display name of the linked catalog row, shown in the picker
  /// summary card. Tracked separately from `_nameCtrl` so renaming the
  /// inventory row's display name doesn't break the link.
  String? _catalogProductName;

  @override
  void initState() {
    super.initState();
    final p = widget.existing;
    if (p != null) {
      _nameCtrl.text = p.name;
      _priceCtrl.text = p.priceTenge.toString();
      _stockCtrl.text = p.stock.toString();
      _emojiCtrl.text = p.emoji ?? '';
      _imageCtrl.text = p.imageUrl ?? '';
      _motorType = p.motorType;
      _curtain = p.curtainMode;
      _categoryId = p.categoryId;
      _catalogProductId = p.catalogProductId;
      _catalogProductName = p.name; // best guess until we fetch the row
    } else {
      _stockCtrl.text = '0';
    }
  }

  /// Apply a catalog selection: prefill the form's name / image / emoji
  /// / category from the SKU so the operator only has to type price +
  /// stock. The original FK is stashed in [_catalogProductId] for the
  /// save call.
  void _applyCatalog(CatalogProduct cp) {
    setState(() {
      _catalogProductId = cp.id;
      _catalogProductName = cp.name;
      _nameCtrl.text = cp.name;
      _emojiCtrl.text = cp.emoji ?? '';
      _imageCtrl.text = cp.imageUrl ?? '';
      _categoryId = cp.categoryId;
    });
  }

  void _clearCatalogLink() {
    setState(() {
      _catalogProductId = null;
      _catalogProductName = null;
    });
  }

  Future<void> _openCatalogPicker() async {
    final picked = await showModalBottomSheet<CatalogProduct>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const _CatalogPickerSheet(),
    );
    if (picked == null || !mounted) return;
    _applyCatalog(picked);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _priceCtrl.dispose();
    _stockCtrl.dispose();
    _emojiCtrl.dispose();
    _imageCtrl.dispose();
    super.dispose();
  }

  String _resolveSlotLabel() {
    final layout = context.read<VendingService>().layout;
    final slot = layout.slotForMotor(widget.motorId);
    return slot?.label ?? widget.motorId.toString().padLeft(3, '0');
  }

  Future<void> _save() async {
    final s = context.read<Strings>();
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_catalogProductId == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Сначала выберите товар из каталога'),
        backgroundColor: Colors.redAccent,
      ));
      return;
    }
    final price = int.tryParse(_priceCtrl.text.trim()) ?? 0;
    final stock = int.tryParse(_stockCtrl.text.trim()) ?? 0;

    // Confirmation step — the operator just bound a product to a
    // physical slot, double-check before committing so a misread label
    // doesn't turn into a 200 ₸ Coca-Cola on the spiral that actually
    // holds water bottles.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Сохранить?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Слот ${_resolveSlotLabel()} · M${widget.motorId}',
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.indigo)),
            const SizedBox(height: 8),
            Text(_nameCtrl.text.trim(),
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text('Цена: $price ₸'),
            Text('Остаток: $stock шт'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final storage = context.read<DeviceStorage>();
    final machid = storage.machid;
    if (machid == null) return;
    setState(() => _saving = true);

    final id = await _api.upsertProduct(
      inventoryId: widget.existing?.id,
      catalogProductId: _catalogProductId!,
      machid: machid,
      motorId: widget.motorId,
      name: _nameCtrl.text.trim(),
      priceTenge: price,
      stock: stock,
      motorType: _motorType,
      curtainMode: _curtain,
      imageUrl: _imageCtrl.text.trim(),
      emoji: _emojiCtrl.text.trim(),
      categoryId: _categoryId,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    final ok = id != null;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? s.t('save_ok') : s.t('save_failed')),
      backgroundColor: ok ? Colors.green : Colors.redAccent,
    ));
    if (ok) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final s = context.read<Strings>();
    final id = widget.existing?.id;
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('btn_delete')),
        content: Text(s.t('confirm_delete')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.t('payment_cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(s.t('btn_delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final deleted = await _api.deleteProduct(id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(deleted ? s.t('save_ok') : s.t('save_failed')),
      backgroundColor: deleted ? Colors.green : Colors.redAccent,
    ));
    if (deleted) Navigator.of(context).pop();
  }

  /// Bulk-apply this slot's bound product + current price (and stock
  /// optionally) to other inventory rows. Operator picks the target
  /// slots from a checklist — settings are written via the same
  /// upsertProduct API, then the local catalog refreshes.
  Future<void> _openBulkApply() async {
    if (_catalogProductId == null) return;
    final svc = context.read<VendingService>();
    final storage = context.read<DeviceStorage>();
    final machid = storage.machid;
    if (machid == null) return;

    final price = int.tryParse(_priceCtrl.text.trim()) ?? 0;
    final stock = int.tryParse(_stockCtrl.text.trim()) ?? 0;
    final candidates = svc.catalog
        .where((p) => p.id != widget.existing?.id)
        .toList()
      ..sort((a, b) => a.motorId.compareTo(b.motorId));

    final result = await showModalBottomSheet<_BulkApplyResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _BulkApplySheet(
        candidates: candidates,
        currentName: _nameCtrl.text.trim(),
        currentPrice: price,
        currentStock: stock,
        layout: svc.layout,
      ),
    );
    if (result == null || result.targets.isEmpty || !mounted) return;

    setState(() => _saving = true);
    var ok = 0;
    for (final target in result.targets) {
      final id = await _api.upsertProduct(
        inventoryId: target.id,
        catalogProductId: _catalogProductId!,
        machid: machid,
        motorId: target.motorId,
        name: _nameCtrl.text.trim(),
        priceTenge: result.applyPrice ? price : target.priceTenge,
        stock: result.applyStock ? stock : target.stock,
        motorType: target.motorType,
        curtainMode: target.curtainMode,
        imageUrl: _imageCtrl.text.trim(),
        emoji: _emojiCtrl.text.trim(),
        categoryId: _categoryId,
      );
      if (id != null) ok++;
    }
    if (!mounted) return;
    await svc.reload(silent: true);
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Применено к $ok из ${result.targets.length} слотов'),
      backgroundColor:
          ok == result.targets.length ? Colors.green : Colors.orange,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    // Resolve the label from the operator-built layout when available
    // so badge text matches what the editor shows (e.g. "11" on MP2404,
    // "001" on factory 6×6). Falls back to the bare motor id when the
    // motor isn't mapped to any slot yet.
    final layout = context.watch<VendingService>().layout;
    final slot = layout.slotForMotor(widget.motorId);
    final shelf = slot?.label ?? widget.motorId.toString().padLeft(3, '0');
    final isNew = widget.existing == null;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      appBar: AppBar(
        title: Text(isNew ? s.t('product_new_title') : s.t('product_edit_title')),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        actions: [
          if (!isNew)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              tooltip: s.t('btn_delete'),
              onPressed: _saving ? null : _delete,
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _slotHeader(s, shelf),
            const SizedBox(height: 12),
            _catalogCard(),
            const SizedBox(height: 20),
            // Hidden name field — required by the Form to validate
            // before save (creating drafts uses _nameCtrl text). Kept
            // out of the visual flow now that catalog picker drives
            // every name change.
            Offstage(
              child: TextFormField(
                controller: _nameCtrl,
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? s.t('name_required')
                    : null,
              ),
            ),
            _sectionLabel('ВИТРИНА'),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _priceCtrl,
                    decoration: InputDecoration(
                      labelText: s.t('field_price'),
                      filled: true,
                      fillColor: Colors.white,
                      border: const OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _stockCtrl,
                    decoration: InputDecoration(
                      labelText: s.t('field_stock'),
                      filled: true,
                      fillColor: Colors.white,
                      border: const OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Bulk-apply CTA: copy this slot's current product + price
            // onto other inventory rows in one move. Settings like
            // motor wiring stay per-slot (those live in Motor Setup).
            OutlinedButton.icon(
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              label: const Text('Применить к другим слотам'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: _catalogProductId == null || _saving
                  ? null
                  : _openBulkApply,
            ),
            const SizedBox(height: 8),
            const Text(
              'Тип мотора и режим выдачи задаются в разделе '
              '«Настройка моторов».',
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.save),
              label: Text(s.t('btn_save'),
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              onPressed: _saving ? null : _save,
            ),
          ],
        ),
      ),
    );
  }

  /// "Pick from catalog" affordance shown above the form. Two states:
  ///   • Linked  — shows the catalog SKU's thumbnail + name + a button
  ///               to swap or unlink. Editing operator can still tweak
  ///               name/image/category on the inventory row.
  ///   • Unlinked — shows just a "Выбрать из каталога" CTA. Saving in
  ///               this state will create a draft `products` row
  ///               (admin can promote it later).
  Widget _catalogCard() {
    final linked = _catalogProductId != null;
    if (!linked) {
      return Material(
        color: Colors.indigo.shade50,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _openCatalogPicker,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Icon(Icons.menu_book, color: Colors.indigo.shade700),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Выбрать из каталога',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Colors.indigo.shade900,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Подтянуть фото и название из готового товара',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.indigo.shade400,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: Colors.indigo.shade300),
              ],
            ),
          ),
        ),
      );
    }
    final img = _imageCtrl.text.trim();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green.shade200),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: img.isEmpty
                ? Container(
                    width: 40,
                    height: 40,
                    color: Colors.green.shade100,
                    alignment: Alignment.center,
                    child: Text(
                      _emojiCtrl.text.trim().isEmpty
                          ? '📦'
                          : _emojiCtrl.text.trim(),
                      style: const TextStyle(fontSize: 20),
                    ),
                  )
                : Image.network(
                    img,
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 40,
                      height: 40,
                      color: Colors.green.shade100,
                      alignment: Alignment.center,
                      child: const Text('📦',
                          style: TextStyle(fontSize: 20)),
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.check_circle,
                        color: Colors.green.shade700, size: 14),
                    const SizedBox(width: 4),
                    Text(
                      'Из каталога',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.green.shade800,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _catalogProductName ?? _nameCtrl.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Сменить',
            icon: const Icon(Icons.swap_horiz),
            onPressed: _openCatalogPicker,
          ),
          IconButton(
            tooltip: 'Отвязать',
            icon: const Icon(Icons.link_off, color: Colors.redAccent),
            onPressed: _clearCatalogLink,
          ),
        ],
      ),
    );
  }

  Widget _slotHeader(Strings s, String shelf) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.indigo.shade50,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.indigo.shade700,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              shelf,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${s.t('motor_label')} ${widget.motorId}',
            style: TextStyle(
                color: Colors.indigo.shade900,
                fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Colors.grey.shade700,
          ),
        ),
      );
}

/// Bottom-sheet that lists active `products` rows from Supabase with a
/// search box. Pops the selected [CatalogProduct] so the parent screen
/// can prefill the form.
class _CatalogPickerSheet extends StatefulWidget {
  const _CatalogPickerSheet();

  @override
  State<_CatalogPickerSheet> createState() => _CatalogPickerSheetState();
}

class _CatalogPickerSheetState extends State<_CatalogPickerSheet> {
  final _api = SupabaseApi();
  final _searchCtrl = TextEditingController();
  List<CatalogProduct>? _all;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await _api.fetchProducts();
    if (!mounted) return;
    setState(() {
      if (r.isOk) {
        _all = r.data;
      } else {
        _error = r.error;
      }
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<CatalogProduct> get _filtered {
    final list = _all ?? const <CatalogProduct>[];
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return list;
    return list
        .where((p) => p.name.toLowerCase().contains(q))
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollCtrl) {
        return Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Каталог товаров',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w800),
                    ),
                  ),
                  if (_all != null)
                    Text(
                      '${_filtered.length} / ${_all!.length}',
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade600),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Поиск',
                  filled: true,
                  fillColor: Colors.grey.shade100,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            Expanded(child: _buildBody(scrollCtrl)),
          ],
        );
      },
    );
  }

  Widget _buildBody(ScrollController scrollCtrl) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline,
                  size: 40, color: Colors.red.shade400),
              const SizedBox(height: 8),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.black54)),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () {
                  setState(() {
                    _error = null;
                    _all = null;
                  });
                  _load();
                },
                child: const Text('Повторить'),
              ),
            ],
          ),
        ),
      );
    }
    if (_all == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final items = _filtered;
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _searchCtrl.text.isEmpty
                ? 'Каталог пуст. Добавьте товары в admin-панели.'
                : 'Ничего не найдено',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: scrollCtrl,
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
      itemCount: items.length,
      itemBuilder: (_, i) => _CatalogTile(
        product: items[i],
        onTap: () => Navigator.of(context).pop(items[i]),
      ),
    );
  }
}

class _CatalogTile extends StatelessWidget {
  const _CatalogTile({required this.product, required this.onTap});

  final CatalogProduct product;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: product.imageUrl != null && product.imageUrl!.isNotEmpty
            ? Image.network(
                product.imageUrl!,
                width: 48,
                height: 48,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _emojiBox(product.emoji),
                loadingBuilder: (_, child, p) =>
                    p == null ? child : _emojiBox(product.emoji),
              )
            : _emojiBox(product.emoji),
      ),
      title: Text(
        product.name,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: product.volumeMl != null
          ? Text('${product.volumeMl} мл',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12))
          : null,
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }

  Widget _emojiBox(String? emoji) => Container(
        width: 48,
        height: 48,
        color: Colors.indigo.shade50,
        alignment: Alignment.center,
        child: Text(
          emoji?.isNotEmpty == true ? emoji! : '📦',
          style: const TextStyle(fontSize: 22),
        ),
      );
}

/// Result returned by [_BulkApplySheet]: selected target inventory
/// rows + flags for which source-slot fields to copy. Settings tied to
/// physical wiring (motor_type, curtain_mode) are intentionally never
/// in the toggle list — those belong to Motor Setup.
class _BulkApplyResult {
  _BulkApplyResult({
    required this.targets,
    required this.applyPrice,
    required this.applyStock,
  });
  final List<Product> targets;
  final bool applyPrice;
  final bool applyStock;
}

class _BulkApplySheet extends StatefulWidget {
  const _BulkApplySheet({
    required this.candidates,
    required this.currentName,
    required this.currentPrice,
    required this.currentStock,
    required this.layout,
  });

  final List<Product> candidates;
  final String currentName;
  final int currentPrice;
  final int currentStock;
  final MachineLayout layout;

  @override
  State<_BulkApplySheet> createState() => _BulkApplySheetState();
}

class _BulkApplySheetState extends State<_BulkApplySheet> {
  final Set<String> _selected = {};
  bool _applyPrice = true;
  bool _applyStock = false;

  String _labelFor(int motorId) =>
      widget.layout.slotForMotor(motorId)?.label ??
      motorId.toString().padLeft(3, '0');

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollCtrl) {
        return Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Применить к другим слотам',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(
                    'Скопирует «${widget.currentName}» на выбранные '
                    'слоты с привязкой к каталогу.',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.black54),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: FilterChip(
                      selected: _applyPrice,
                      label: Text('Цена ${widget.currentPrice} ₸'),
                      onSelected: (v) => setState(() => _applyPrice = v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilterChip(
                      selected: _applyStock,
                      label: Text('Остаток ${widget.currentStock}'),
                      onSelected: (v) => setState(() => _applyStock = v),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  Text(
                    'Выбрано: ${_selected.length}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _selected.length == widget.candidates.length
                        ? () => setState(() => _selected.clear())
                        : () => setState(() {
                              _selected
                                ..clear()
                                ..addAll(widget.candidates.map((p) => p.id!));
                            }),
                    child: Text(
                      _selected.length == widget.candidates.length
                          ? 'Снять'
                          : 'Все',
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: scrollCtrl,
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                itemCount: widget.candidates.length,
                itemBuilder: (_, i) {
                  final p = widget.candidates[i];
                  final id = p.id;
                  if (id == null) return const SizedBox.shrink();
                  final picked = _selected.contains(id);
                  return CheckboxListTile(
                    dense: true,
                    value: picked,
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          _selected.add(id);
                        } else {
                          _selected.remove(id);
                        }
                      });
                    },
                    title: Text(
                      p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      'Слот ${_labelFor(p.motorId)} · M${p.motorId} · '
                      '${p.priceTenge} ₸ · ×${p.stock}',
                      style: const TextStyle(fontSize: 11),
                    ),
                  );
                },
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Отмена'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        icon: const Icon(Icons.done_all, size: 18),
                        label: Text('Применить (${_selected.length})'),
                        onPressed: _selected.isEmpty ||
                                (!_applyPrice && !_applyStock)
                            ? null
                            : () {
                                final targets = widget.candidates
                                    .where((p) =>
                                        p.id != null && _selected.contains(p.id))
                                    .toList();
                                Navigator.of(context).pop(_BulkApplyResult(
                                  targets: targets,
                                  applyPrice: _applyPrice,
                                  applyStock: _applyStock,
                                ));
                              },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
