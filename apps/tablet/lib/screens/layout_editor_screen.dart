import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../board/board_client.dart';
import '../models/machine_layout.dart';
import '../services/device_storage.dart';
import '../services/strings.dart';
import '../services/vending_service.dart';
import '../theme.dart';

/// Human label for a motor id. BarysVend positions decode to "Р2·К3"
/// (both the canonical ряд×100+колонка ids and the legacy 11..100
/// encoding); M102 channel numbers stay as-is.
String _motorLabel(int id, {required bool isLyt}) {
  if (!isLyt && id < 101) return '$id';
  final (r, c) = BoardClient.lytRowColFromMotorId(id);
  return 'Р$r·К$c';
}

/// Service-mode editor for the per-machine layout: shelves + slots +
/// twin-spiral groupings. Persists locally via
/// [VendingService.setLayout] → [DeviceStorage.setMachineLayoutJson],
/// no network involved.
///
/// Lay-out:
///   • Left rail — list of shelves with [+] button to add more.
///     Tap to select; long-press to rename / delete.
///   • Right panel — slots of the selected shelf as cards. Each card
///     shows the slot label + the motor id(s) it owns. [+] adds a
///     new slot via the motor picker, which also auto-detects which
///     motors are wired by running 0x04 scan on the entire 0..99 range.
class LayoutEditorScreen extends StatefulWidget {
  const LayoutEditorScreen({super.key});

  @override
  State<LayoutEditorScreen> createState() => _LayoutEditorScreenState();
}

class _LayoutEditorScreenState extends State<LayoutEditorScreen> {
  late MachineLayout _draft;
  int _selectedShelf = 0;

  /// Result of the last 0x04 Motor Scan, keyed by motor id.
  /// 0xAA = wired, 0xBB = empty, 0xCC = overload, null = not scanned.
  final Map<int, int?> _scanResults = {};
  bool _scanning = false;
  int _scanProgress = 0;

  /// Operator-saved templates, hydrated from [DeviceStorage] and kept
  /// in sync with it on every save/delete.
  List<CustomLayoutTemplate> _customTemplates = [];

  @override
  void initState() {
    super.initState();
    _draft = context.read<VendingService>().layout;
    if (_draft.shelves.isEmpty) _selectedShelf = -1;
    _customTemplates = CustomLayoutTemplate.decodeList(
        context.read<DeviceStorage>().customLayoutTemplatesJson);
  }

  Future<void> _persistCustomTemplates() =>
      context.read<DeviceStorage>().setCustomLayoutTemplatesJson(
          _customTemplates.isEmpty
              ? null
              : CustomLayoutTemplate.encodeList(_customTemplates));

  /// Snapshot the current draft under an operator-chosen name. A deep
  /// copy (JSON round-trip) is stored so further editing of the draft
  /// can't mutate the saved template.
  Future<void> _saveAsTemplate() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_draft.isEmpty) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Раскладка пуста — нечего сохранять'),
        backgroundColor: Colors.redAccent,
      ));
      return;
    }
    final ctrl = TextEditingController(
        text: 'Шаблон ${_customTemplates.length + 1}');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Сохранить как шаблон'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Название шаблона',
            hintText: 'например BarysVend кофейня',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;

    final existingIdx = _customTemplates.indexWhere((t) => t.name == name);
    if (existingIdx >= 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Перезаписать шаблон?'),
          content: Text('Шаблон «$name» уже существует.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Перезаписать'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }

    final snapshot = CustomLayoutTemplate(
      name: name,
      layout: MachineLayout.fromJson(_draft.toJson()),
    );
    setState(() {
      if (existingIdx >= 0) {
        _customTemplates[existingIdx] = snapshot;
      } else {
        _customTemplates.add(snapshot);
      }
    });
    await _persistCustomTemplates();
    messenger.showSnackBar(SnackBar(
      content: Text('Шаблон «$name» сохранён'),
      backgroundColor: Colors.green,
    ));
  }

  static String _describeLayout(MachineLayout l) {
    var slots = 0;
    for (final sh in l.shelves) {
      slots += sh.slots.length;
    }
    return 'Полок: ${l.shelves.length} · слотов: $slots';
  }

  Future<void> _save() async {
    await context.read<VendingService>().setLayout(_draft);
    if (mounted) Navigator.of(context).pop();
  }

  /// Opens a sheet listing the built-in [LayoutTemplate]s plus the
  /// operator's own saved ones («Мои шаблоны», deletable in place).
  /// Tapping a template confirms (current draft will be overwritten)
  /// and replaces `_draft` with a fresh copy. Labels and motor ids stay
  /// editable afterwards via the normal slot picker.
  Future<void> _pickTemplate() async {
    // LayoutTemplate | CustomLayoutTemplate — the sheet returns either.
    final chosen = await showModalBottomSheet<Object>(
      context: context,
      backgroundColor: Colors.grey.shade900,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: StatefulBuilder(builder: (ctx, setSheet) {
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Выберите шаблон',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                for (final tpl in LayoutTemplate.all)
                  ListTile(
                    leading:
                        const Icon(Icons.grid_view, color: Colors.white70),
                    title: Text(tpl.name,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700)),
                    subtitle: Text(tpl.description,
                        style: const TextStyle(color: Colors.white60)),
                    onTap: () => Navigator.of(ctx).pop(tpl),
                  ),
                if (_customTemplates.isNotEmpty) ...[
                  const Divider(color: Colors.white24, height: 16),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'МОИ ШАБЛОНЫ',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  ),
                  for (final t in List.of(_customTemplates))
                    ListTile(
                      leading: const Icon(Icons.bookmark,
                          color: Colors.amberAccent),
                      title: Text(t.name,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700)),
                      subtitle: Text(_describeLayout(t.layout),
                          style: const TextStyle(color: Colors.white60)),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline,
                            color: Colors.white54),
                        tooltip: 'Удалить шаблон',
                        onPressed: () async {
                          final ok = await showDialog<bool>(
                            context: ctx,
                            builder: (dctx) => AlertDialog(
                              title: const Text('Удалить шаблон?'),
                              content: Text('«${t.name}» будет удалён. '
                                  'Текущая раскладка не изменится.'),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(dctx).pop(false),
                                  child: const Text('Отмена'),
                                ),
                                FilledButton(
                                  onPressed: () =>
                                      Navigator.of(dctx).pop(true),
                                  child: const Text('Удалить'),
                                ),
                              ],
                            ),
                          );
                          if (ok != true) return;
                          setState(() => _customTemplates
                              .removeWhere((x) => x.name == t.name));
                          setSheet(() {});
                          await _persistCustomTemplates();
                        },
                      ),
                      onTap: () => Navigator.of(ctx).pop(t),
                    ),
                ],
                const SizedBox(height: 8),
              ],
            ),
          );
        }),
      ),
    );
    if (chosen == null || !mounted) return;

    final String name;
    final MachineLayout layout;
    if (chosen is LayoutTemplate) {
      name = chosen.name;
      layout = chosen.build();
    } else if (chosen is CustomLayoutTemplate) {
      name = chosen.name;
      // Deep copy: the draft must never share objects with the stored
      // template, or editing one would silently edit the other.
      layout = MachineLayout.fromJson(chosen.layout.toJson());
    } else {
      return;
    }

    if (_draft.shelves.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Перезаписать раскладку?'),
          content: Text(
              'Текущая раскладка будет заменена на «$name». '
              'Подписи и моторы можно будет править после применения.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Применить'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }

    setState(() {
      _draft = layout;
      _selectedShelf = _draft.shelves.isEmpty ? -1 : 0;
    });
  }

  void _addShelf() {
    final nextLabel = 'Полка ${_draft.shelves.length + 1}';
    setState(() {
      _draft = _draft.copyWith(
        shelves: [..._draft.shelves, Shelf(label: nextLabel, slots: const [])],
      );
      _selectedShelf = _draft.shelves.length - 1;
    });
  }

  Future<void> _renameShelf(int index) async {
    final ctrl = TextEditingController(text: _draft.shelves[index].label);
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Название полки'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (picked == null || picked.isEmpty) return;
    setState(() {
      final list = [..._draft.shelves];
      list[index] = list[index].copyWith(label: picked);
      _draft = _draft.copyWith(shelves: list);
    });
  }

  void _deleteShelf(int index) {
    setState(() {
      final list = [..._draft.shelves]..removeAt(index);
      _draft = _draft.copyWith(shelves: list);
      if (_selectedShelf >= list.length) _selectedShelf = list.length - 1;
    });
  }

  Future<void> _addSlot() async {
    if (_selectedShelf < 0) return;
    final result = await _openSlotPicker();
    if (result == null) return;
    setState(() {
      final shelves = [..._draft.shelves];
      final shelf = shelves[_selectedShelf];
      shelves[_selectedShelf] =
          shelf.copyWith(slots: [...shelf.slots, result]);
      _draft = _draft.copyWith(shelves: shelves);
    });
  }

  Future<void> _editSlot(int slotIndex) async {
    final current = _draft.shelves[_selectedShelf].slots[slotIndex];
    final result = await _openSlotPicker(initial: current);
    if (result == null) return;
    setState(() {
      final shelves = [..._draft.shelves];
      final shelf = shelves[_selectedShelf];
      final newSlots = [...shelf.slots];
      newSlots[slotIndex] = result;
      shelves[_selectedShelf] = shelf.copyWith(slots: newSlots);
      _draft = _draft.copyWith(shelves: shelves);
    });
  }

  void _deleteSlot(int slotIndex) {
    setState(() {
      final shelves = [..._draft.shelves];
      final shelf = shelves[_selectedShelf];
      final newSlots = [...shelf.slots]..removeAt(slotIndex);
      shelves[_selectedShelf] = shelf.copyWith(slots: newSlots);
      _draft = _draft.copyWith(shelves: shelves);
    });
  }

  /// Walks motor IDs 0..99, sends 0x04 Motor Scan to each, stores the
  /// AA/BB/CC byte. UI shows progress and re-renders the picker cells
  /// live so the operator sees the cabinet light up channel by channel.
  Future<void> _scanAll() async {
    final board = context.read<BoardClient>();
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _scanProgress = 0;
      _scanResults.clear();
    });
    for (var i = 0; i < 100; i++) {
      if (!mounted) return;
      final code = await board.scanMotor(i);
      if (!mounted) return;
      setState(() {
        _scanResults[i] = code;
        _scanProgress = i + 1;
      });
    }
    if (!mounted) return;
    setState(() => _scanning = false);
  }

  /// Modal that lets the operator pick a label + multiple motor ids
  /// for one slot. Returns the new/edited [Slot] or null if cancelled.
  ///
  /// The grid depends on the board protocol: M102 exposes flat channels
  /// 0..99 (with the 0x04 wiring scan), while BarysVend V27.2 addresses
  /// (ряд, колонка) — the grid is laid out as 9 rows × 10 columns and
  /// each cell carries the encoded id = ряд×10+колонка (11..100), so
  /// the operator picks a physical position, not an abstract channel.
  Future<Slot?> _openSlotPicker({Slot? initial}) async {
    final isLyt = context.read<BoardClient>().isLyt;
    final labelCtrl =
        TextEditingController(text: initial?.label ?? _suggestSlotLabel());
    final selected = <int>{...(initial?.motorIds ?? const [])};
    final usedElsewhere = _draft.allUsedMotorIds.difference(
      (initial?.motorIds ?? const <int>[]).toSet(),
    );
    // BarysVend position being composed in the dropdowns.
    var pickRow = 1;
    var pickCol = 1;
    return showDialog<Slot>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setLocal) {
          return Dialog(
            insetPadding: const EdgeInsets.all(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 540, maxHeight: 720),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Слот',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        // LiYuTai has no non-destructive motor scan —
                        // the board only ever answers a real dispense.
                        if (!isLyt)
                          TextButton.icon(
                            icon: const Icon(Icons.search),
                            label: Text(_scanning
                                ? 'Сканирование $_scanProgress / 100…'
                                : 'Сканировать моторы'),
                            onPressed: _scanning ? null : _scanAll,
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: labelCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Подпись слота',
                        hintText: 'например 001',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      isLyt
                          ? 'Задайте позицию мотора рядом и колонкой '
                              '(2+ позиции для сдвоенного слота).  '
                              '${selected.length} выбрано.'
                          : 'Выберите motor id (1+ для сдвоенного слота).  '
                              '${selected.length} выбрано.',
                      style: const TextStyle(
                          fontSize: 12, color: Colors.black54),
                    ),
                    const SizedBox(height: 8),
                    if (isLyt)
                      // BarysVend: the operator thinks in physical
                      // (ряд, колонка) — compose the position from two
                      // dropdowns; the id stores ряд×100+колонка.
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: DropdownButtonFormField<int>(
                                    initialValue: pickRow,
                                    decoration: const InputDecoration(
                                      labelText: 'Ряд (L)',
                                      border: OutlineInputBorder(),
                                    ),
                                    items: [
                                      for (var r = 1; r <= 10; r++)
                                        DropdownMenuItem(
                                            value: r, child: Text('$r')),
                                    ],
                                    onChanged: (v) => setLocal(
                                        () => pickRow = v ?? pickRow),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: DropdownButtonFormField<int>(
                                    initialValue: pickCol,
                                    decoration: const InputDecoration(
                                      labelText: 'Колонка (C)',
                                      border: OutlineInputBorder(),
                                    ),
                                    items: [
                                      for (var c = 1; c <= 14; c++)
                                        DropdownMenuItem(
                                            value: c, child: Text('$c')),
                                    ],
                                    onChanged: (v) => setLocal(
                                        () => pickCol = v ?? pickCol),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                FilledButton.icon(
                                  icon: const Icon(Icons.add),
                                  label: const Text('Добавить'),
                                  onPressed: usedElsewhere.contains(
                                          BoardClient.lytMotorIdFor(
                                              pickRow, pickCol))
                                      ? null
                                      : () => setLocal(() => selected.add(
                                          BoardClient.lytMotorIdFor(
                                              pickRow, pickCol))),
                                ),
                              ],
                            ),
                            if (usedElsewhere.contains(
                                BoardClient.lytMotorIdFor(pickRow, pickCol)))
                              const Padding(
                                padding: EdgeInsets.only(top: 6),
                                child: Text(
                                  'Эта позиция уже занята другим слотом',
                                  style: TextStyle(
                                      fontSize: 11, color: Colors.redAccent),
                                ),
                              ),
                            const SizedBox(height: 12),
                            Expanded(
                              child: SingleChildScrollView(
                                child: Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    for (final id in selected.toList()
                                      ..sort())
                                      InputChip(
                                        label: Text(
                                            _motorLabel(id, isLyt: true)),
                                        onDeleted: () => setLocal(
                                            () => selected.remove(id)),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      Expanded(
                        child: GridView.builder(
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 10,
                            mainAxisSpacing: 4,
                            crossAxisSpacing: 4,
                            childAspectRatio: 1,
                          ),
                          itemCount: 100,
                          itemBuilder: (ctx, i) {
                            final code = _scanResults[i];
                            final isSelected = selected.contains(i);
                            final isTaken = usedElsewhere.contains(i);
                            return _MotorCell(
                              motorId: i,
                              scanResult: code,
                              selected: isSelected,
                              takenByOther: isTaken,
                              onTap: isTaken && !isSelected
                                  ? null
                                  : () {
                                      setLocal(() {
                                        if (isSelected) {
                                          selected.remove(i);
                                        } else {
                                          selected.add(i);
                                        }
                                      });
                                    },
                            );
                          },
                        ),
                      ),
                    const SizedBox(height: 8),
                    _ScanLegend(isLyt: isLyt),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: const Text('Отмена'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: selected.isEmpty
                              ? null
                              : () {
                                  final list = selected.toList()..sort();
                                  Navigator.of(ctx).pop(
                                    Slot(
                                      label: labelCtrl.text.trim().isEmpty
                                          ? _suggestSlotLabel()
                                          : labelCtrl.text.trim(),
                                      motorIds: list,
                                    ),
                                  );
                                },
                          child: const Text('Сохранить слот'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        });
      },
    );
  }

  String _suggestSlotLabel() {
    var count = 0;
    for (final sh in _draft.shelves) {
      count += sh.slots.length;
    }
    return (count + 1).toString().padLeft(3, '0');
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    return Scaffold(
      backgroundColor: Colors.grey.shade900,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(s.t('service_layout_editor'),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            tooltip: 'Сохранить как шаблон',
            icon: const Icon(Icons.bookmark_add_outlined),
            onPressed: _saveAsTemplate,
          ),
          IconButton(
            tooltip: 'Шаблоны раскладки',
            icon: const Icon(Icons.dashboard_customize),
            onPressed: _pickTemplate,
          ),
          IconButton(
            tooltip: 'Сохранить',
            icon: const Icon(Icons.check),
            onPressed: _save,
          ),
        ],
      ),
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ShelfRail(
              shelves: _draft.shelves,
              selectedIndex: _selectedShelf,
              onSelect: (i) => setState(() => _selectedShelf = i),
              onAdd: _addShelf,
              onRename: _renameShelf,
              onDelete: _deleteShelf,
            ),
            const VerticalDivider(width: 1, color: Colors.white24),
            Expanded(
              child: _SlotsPanel(
                shelf: _selectedShelf >= 0 &&
                        _selectedShelf < _draft.shelves.length
                    ? _draft.shelves[_selectedShelf]
                    : null,
                isLyt: context.watch<BoardClient>().isLyt,
                onAddSlot: _addSlot,
                onEditSlot: _editSlot,
                onDeleteSlot: _deleteSlot,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShelfRail extends StatelessWidget {
  const _ShelfRail({
    required this.shelves,
    required this.selectedIndex,
    required this.onSelect,
    required this.onAdd,
    required this.onRename,
    required this.onDelete,
  });

  final List<Shelf> shelves;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onAdd;
  final void Function(int) onRename;
  final void Function(int) onDelete;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 180,
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: shelves.length,
              itemBuilder: (ctx, i) {
                final active = i == selectedIndex;
                return Material(
                  color: active ? Colors.white12 : Colors.transparent,
                  child: InkWell(
                    onTap: () => onSelect(i),
                    onLongPress: () => _showShelfActions(ctx, i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 14),
                      child: Row(
                        children: [
                          Container(
                            width: 6,
                            height: 24,
                            decoration: BoxDecoration(
                              color: active
                                  ? AppColors.iosBlue
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              shelves[i].label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withValues(
                                    alpha: active ? 1 : 0.7),
                                fontWeight: active
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                          ),
                          Text(
                            '${shelves[i].slots.length}',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Полка'),
              onPressed: onAdd,
            ),
          ),
        ],
      ),
    );
  }

  void _showShelfActions(BuildContext context, int i) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Переименовать'),
              onTap: () {
                Navigator.of(ctx).pop();
                onRename(i);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.redAccent),
              title: const Text('Удалить полку',
                  style: TextStyle(color: Colors.redAccent)),
              onTap: () {
                Navigator.of(ctx).pop();
                onDelete(i);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SlotsPanel extends StatelessWidget {
  const _SlotsPanel({
    required this.shelf,
    required this.isLyt,
    required this.onAddSlot,
    required this.onEditSlot,
    required this.onDeleteSlot,
  });

  final Shelf? shelf;
  final bool isLyt;
  final VoidCallback onAddSlot;
  final void Function(int) onEditSlot;
  final void Function(int) onDeleteSlot;

  @override
  Widget build(BuildContext context) {
    if (shelf == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Добавьте полку слева, чтобы начать раскладку',
            style: TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final slots = shelf!.slots;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  shelf!.label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Слот'),
                onPressed: onAddSlot,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: slots.isEmpty
                ? const Center(
                    child: Text('Слотов ещё нет — нажмите «Слот»',
                        style: TextStyle(color: Colors.white54)))
                : GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 1.6,
                    ),
                    itemCount: slots.length,
                    itemBuilder: (ctx, i) {
                      final sl = slots[i];
                      return Material(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => onEditSlot(i),
                          onLongPress: () => onDeleteSlot(i),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  sl.label,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const Spacer(),
                                Row(
                                  children: [
                                    if (sl.isTwin)
                                      Container(
                                        margin: const EdgeInsets.only(right: 6),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: AppColors.iosOrange
                                              .withValues(alpha: 0.25),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: const Text('TWIN',
                                            style: TextStyle(
                                              color: AppColors.iosOrange,
                                              fontSize: 9,
                                              fontWeight: FontWeight.w900,
                                              letterSpacing: 1.2,
                                            )),
                                      ),
                                    Expanded(
                                      child: Text(
                                        isLyt
                                            ? sl.motorIds
                                                .map((m) => _motorLabel(m,
                                                    isLyt: true))
                                                .join(', ')
                                            : 'motors: '
                                                '${sl.motorIds.join(", ")}',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 11,
                                          fontFamily: 'monospace',
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _MotorCell extends StatelessWidget {
  const _MotorCell({
    required this.motorId,
    required this.scanResult,
    required this.selected,
    required this.takenByOther,
    required this.onTap,
  });

  final int motorId;
  final int? scanResult;
  final bool selected;
  final bool takenByOther;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    if (selected) {
      bg = AppColors.iosBlue;
      fg = Colors.white;
    } else if (takenByOther) {
      bg = Colors.grey.shade300;
      fg = Colors.grey.shade500;
    } else {
      switch (scanResult) {
        case 0xAA:
          bg = Colors.green.shade100;
          fg = Colors.green.shade900;
          break;
        case 0xBB:
          bg = Colors.grey.shade200;
          fg = Colors.grey.shade500;
          break;
        case 0xCC:
          bg = Colors.orange.shade100;
          fg = Colors.orange.shade900;
          break;
        default:
          bg = Colors.white;
          fg = Colors.black54;
      }
    }
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Center(
          child: Text(
            motorId.toString().padLeft(2, '0'),
            style: TextStyle(
              color: fg,
              fontSize: 11,
              fontWeight:
                  selected || scanResult == 0xAA ? FontWeight.w800 : FontWeight.w500,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ),
    );
  }
}

class _ScanLegend extends StatelessWidget {
  const _ScanLegend({required this.isLyt});

  /// BarysVend mode has no wiring scan, so the AA/BB/CC legend would
  /// only mislead — explain the row×column numbering instead.
  final bool isLyt;

  @override
  Widget build(BuildContext context) {
    if (isLyt) {
      return const Text(
        'Ряд (L) — полка сверху вниз, колонка (C) — мотор слева направо. '
        'Если крутится не тот мотор — включите «Ряд↔колонка» во вкладке '
        '«Плата».',
        style: TextStyle(fontSize: 11, color: Colors.black54),
      );
    }
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: const [
        _LegendDot(color: Colors.green, text: 'AA — мотор подключён'),
        _LegendDot(color: Colors.grey, text: 'BB — пусто / обрыв'),
        _LegendDot(color: Colors.orange, text: 'CC — перегрузка'),
        _LegendDot(color: AppColors.iosBlue, text: 'выбран'),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.text});

  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 4),
        Text(text, style: const TextStyle(fontSize: 11)),
      ],
    );
  }
}
