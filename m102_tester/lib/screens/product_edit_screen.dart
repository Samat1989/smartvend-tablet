import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../board/board_client.dart';
import '../models/motor_layout.dart';
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
    } else {
      _stockCtrl.text = '0';
    }
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
    final id = await _api.upsertProduct(
      productId: widget.existing?.id,
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
    final shelf = MotorLayout.motorToLabel(widget.motorId);
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
