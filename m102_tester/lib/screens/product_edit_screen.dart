import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../board/board_client.dart';
import '../models/catalog_product.dart';
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
  bool _testing = false;
  bool _testingCurtain = false;

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

  Future<void> _save() async {
    final s = context.read<Strings>();
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final storage = context.read<DeviceStorage>();
    final machid = storage.machid;
    if (machid == null) return;
    setState(() => _saving = true);

    // inventory.product_id is NOT NULL — if the operator typed a name
    // freehand without picking from the catalog, create a draft SKU
    // first so admin can review it later. Editing an existing row
    // keeps its current link.
    var catalogId = _catalogProductId;
    if (catalogId == null) {
      catalogId = await _api.createDraftProduct(
        name: _nameCtrl.text.trim(),
        imageUrl: _imageCtrl.text.trim(),
        emoji: _emojiCtrl.text.trim(),
        categoryId: _categoryId,
      );
      if (catalogId == null) {
        if (!mounted) return;
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(s.t('save_failed')),
          backgroundColor: Colors.redAccent,
        ));
        return;
      }
    }

    final id = await _api.upsertProduct(
      inventoryId: widget.existing?.id,
      catalogProductId: catalogId,
      machid: machid,
      motorId: widget.motorId,
      name: _nameCtrl.text.trim(),
      priceTenge: int.tryParse(_priceCtrl.text.trim()) ?? 0,
      stock: int.tryParse(_stockCtrl.text.trim()) ?? 0,
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

  Future<void> _testMotor() async {
    final s = context.read<Strings>();
    final board = context.read<BoardClient>();
    if (!board.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(s.t('board_not_found')),
        backgroundColor: Colors.redAccent,
      ));
      return;
    }
    setState(() => _testing = true);
    // Use the global "real dispense" sensor mode so this button mirrors
    // what an actual paying customer would trigger. The dedicated
    // "Test drop sensor" button below forces curtain=1 for diagnostics.
    final curtain = context.read<DeviceStorage>().dispenseSensorMode;
    final r = await board.dispense(
      widget.motorId,
      type: _motorType,
      curtain: curtain,
    );
    if (!mounted) return;
    setState(() => _testing = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(r.message),
      backgroundColor: r.success ? Colors.green : Colors.redAccent,
    ));
  }

  /// Force-runs the motor with curtain mode `1` regardless of the saved
  /// product setting, to specifically exercise the drop-sensor wiring.
  ///
  /// Per `c:\m109e\api_docsM109E.txt` §6.4: V1 (sensor power) is **only**
  /// driven during a RUN command with curtain ≠ 0. There's no standalone
  /// "power the sensor" opcode, so the only way to verify the IR curtain
  /// is to actually start a motor with curtain on. The result tells us
  /// which physical layer is broken:
  ///   - `result=4`            → board powered V1 but got no SIG response
  ///                              (broken sensor / wiring / no 24V)
  ///   - `result=0, ms == 0`   → motor finished, sensor never tripped
  ///                              (empty slot / misalignment / nothing fell)
  ///   - `result=0, ms > 0`    → sensor confirmed a drop — fully working
  ///   - other result codes    → motor-side fault, sensor inconclusive
  Future<void> _testCurtain() async {
    final s = context.read<Strings>();
    final board = context.read<BoardClient>();
    if (!board.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(s.t('board_not_found')),
        backgroundColor: Colors.redAccent,
      ));
      return;
    }
    setState(() => _testingCurtain = true);
    final r = await board.dispense(
      widget.motorId,
      type: _motorType,
      curtain: 1,
    );
    if (!mounted) return;
    setState(() => _testingCurtain = false);

    final code = r.finalStatus?.result;
    final ms = r.finalStatus?.curtainMs ?? 0;

    String message;
    Color color;
    if (code == 4) {
      message = s.t('sensor_self_test_fail');
      color = Colors.redAccent;
    } else if (code == 0 && ms > 0) {
      message = '${s.t('sensor_ok')} ($ms ${s.t('pcs') == 'pcs' ? 'ms' : 'мс'})';
      color = Colors.green;
    } else if (code == 0 && ms == 0) {
      message = s.t('sensor_no_drop');
      color = Colors.orange;
    } else {
      // Some other motor-side failure — fall back to localized poll label
      // so the operator at least sees what went wrong with the motor.
      final label = code != null ? s.pollResult(code) : r.message;
      message = label;
      color = Colors.redAccent;
    }

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: color,
      duration: const Duration(seconds: 8),
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
            const SizedBox(height: 16),
            TextFormField(
              controller: _nameCtrl,
              decoration: InputDecoration(
                labelText: s.t('field_name'),
                filled: true,
                fillColor: Colors.white,
              ),
              textCapitalization: TextCapitalization.sentences,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? s.t('name_required') : null,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _priceCtrl,
                    decoration: InputDecoration(
                      labelText: s.t('field_price'),
                      filled: true,
                      fillColor: Colors.white,
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                    ],
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
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _emojiCtrl,
              decoration: InputDecoration(
                labelText: s.t('field_emoji'),
                hintText: '🥤',
                filled: true,
                fillColor: Colors.white,
              ),
              maxLength: 4,
            ),
            TextFormField(
              controller: _imageCtrl,
              decoration: InputDecoration(
                labelText: s.t('field_image_url'),
                hintText: 'https://…',
                filled: true,
                fillColor: Colors.white,
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 16),
            _sectionLabel(s.t('field_category')),
            _CategoryPicker(
              selectedId: _categoryId,
              onChanged: (id) => setState(() => _categoryId = id),
            ),
            const SizedBox(height: 16),
            _sectionLabel(s.t('field_motor_type')),
            SegmentedButton<int>(
              segments: [
                ButtonSegment(value: 2, label: Text(s.t('motor_type_2'))),
                ButtonSegment(value: 3, label: Text(s.t('motor_type_3'))),
              ],
              selected: {_motorType},
              onSelectionChanged: (set) =>
                  setState(() => _motorType = set.first),
            ),
            // Per-product drop-sensor setting was removed — the global
            // sensor mode in service menu → «Режим выдачи» now applies
            // to every slot. We still keep the field on the Product model
            // (DB column stays) so the operator can override via SQL if
            // an exotic edge-case ever needs it.
            const SizedBox(height: 24),
            OutlinedButton.icon(
              icon: _testing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.precision_manufacturing),
              label: Text(s.t('btn_test_motor')),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _testing || _testingCurtain || _saving ? null : _testMotor,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: _testingCurtain
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sensors),
              label: Text(s.t('btn_test_sensor')),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                foregroundColor: Colors.lightBlue.shade700,
                side: BorderSide(color: Colors.lightBlue.shade300),
              ),
              onPressed:
                  _testing || _testingCurtain || _saving ? null : _testCurtain,
            ),
            const SizedBox(height: 12),
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

/// Dropdown for picking the product's category. Reads the master list
/// from [VendingService.categories] (loaded once on app start). Includes
/// a "Без категории" sentinel (`null`) for unsetting the FK.
class _CategoryPicker extends StatelessWidget {
  const _CategoryPicker({
    required this.selectedId,
    required this.onChanged,
  });

  final String? selectedId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final cats = context.watch<VendingService>().categories;
    return DropdownButtonFormField<String?>(
      initialValue: selectedId,
      decoration: const InputDecoration(
        filled: true,
        fillColor: Colors.white,
      ),
      items: [
        DropdownMenuItem<String?>(
          value: null,
          child: Text(
            s.t('no_category'),
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        ),
        for (final c in cats)
          DropdownMenuItem<String?>(
            value: c.id,
            child: Text(c.localizedName(s.lang)),
          ),
      ],
      onChanged: onChanged,
    );
  }
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
