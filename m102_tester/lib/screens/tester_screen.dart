import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../board/board_client.dart';
import '../models/machine_layout.dart';
import '../models/product.dart';
import '../services/device_storage.dart';
import '../services/strings.dart';
import '../services/supabase_api.dart';
import '../services/vending_service.dart';
import '../theme.dart';
import 'layout_editor_screen.dart';

/// Motor setup screen («Настройка моторов»).
///
/// Walks the operator-built [MachineLayout] and exposes per-slot
/// wiring controls + a quick test affordance. Top of the screen has
/// a global drop-sensor toggle (off / on / priority) that mirrors
/// [DeviceStorage.dispenseSensorMode] and a "Apply to all slots"
/// action that bulk-writes the chosen mode to every inventory row.
///
/// For each slot:
///   • Motor type (2-wire / 3-wire) — written to `inventory.motor_type`
///   • Per-slot curtain override — written to `inventory.curtain_mode`
///   • Test motor (uses the global curtain mode)
///   • Test drop sensor (forces curtain=1 to exercise the V1 line)
///
/// Slots without an inventory row only get the test buttons — wiring
/// settings can't be persisted because there's nothing to PATCH yet.
class TesterScreen extends StatefulWidget {
  const TesterScreen({super.key});

  @override
  State<TesterScreen> createState() => _TesterScreenState();
}

class _TesterScreenState extends State<TesterScreen> {
  final _api = SupabaseApi();

  /// Currently-running slot key (primary motor id) or null when idle.
  int? _runningSlotKey;

  /// Last test result per slot, keyed by primary motor id.
  final Map<int, bool> _results = {};
  final Map<int, String> _resultText = {};

  /// In-flight wiring PATCH keys (inventory id) so a saving indicator
  /// can render inline without blocking other rows.
  final Set<String> _savingInvIds = {};

  Future<void> _runTest(Slot slot, {required int curtain}) async {
    if (_runningSlotKey != null) return;
    final s = context.read<Strings>();
    final board = context.read<BoardClient>();
    if (!board.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(s.t('board_not_found')),
        backgroundColor: const Color(0xFFB3261E),
      ));
      return;
    }
    final key = slot.primaryMotorId;
    setState(() => _runningSlotKey = key);
    final r = await board.dispenseSlot(
      slot.motorIds,
      type: _motorTypeForSlot(slot),
      curtain: curtain,
    );
    if (!mounted) return;
    final code = r.finalStatus?.result;
    setState(() {
      _runningSlotKey = null;
      _results[key] = r.success;
      _resultText[key] =
          code != null ? s.pollResult(code) : (r.success ? 'OK' : r.message);
    });
  }

  int _motorTypeForSlot(Slot slot) {
    final p = _productForSlot(slot);
    return p?.motorType ?? 2;
  }

  Product? _productForSlot(Slot slot) {
    final svc = context.read<VendingService>();
    final byMotor = {for (final p in svc.catalog) p.motorId: p};
    return byMotor[slot.primaryMotorId];
  }

  Future<void> _patchWiring(Product p, {int? motorType, int? curtain}) async {
    final id = p.id;
    if (id == null) return;
    final svc = context.read<VendingService>();
    final updated = p.copyWith(
      motorType: motorType ?? p.motorType,
      curtainMode: curtain ?? p.curtainMode,
    );
    svc.replaceProduct(updated);
    setState(() => _savingInvIds.add(id));
    final ok = await _api.updateInventoryWiring(
      inventoryId: id,
      motorType: motorType,
      curtainMode: curtain,
    );
    if (!mounted) return;
    setState(() => _savingInvIds.remove(id));
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Не удалось сохранить настройки мотора'),
        backgroundColor: Color(0xFFB3261E),
      ));
      svc.replaceProduct(p); // revert
    }
  }

  Future<void> _applyGlobalCurtainToAll(int curtain) async {
    final svc = context.read<VendingService>();
    final ids = [
      for (final p in svc.catalog)
        if (p.id != null) p.id!,
    ];
    if (ids.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Применить ко всем слотам?'),
        content: Text(
            'Режим выдачи будет установлен на «${_curtainName(curtain)}» '
            'для всех ${ids.length} слотов с товарами.'),
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
    if (confirmed != true || !mounted) return;
    final n = await _api.bulkUpdateCurtain(
      inventoryIds: ids,
      curtainMode: curtain,
    );
    if (!mounted) return;
    // Refresh catalog so the new per-slot values land in memory.
    await svc.reload(silent: true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Обновлено $n из ${ids.length} слотов'),
      backgroundColor:
          n == ids.length ? Colors.green : Colors.orange,
    ));
  }

  String _curtainName(int v) => switch (v) {
        0 => 'Без проверки',
        1 => 'С датчиком',
        2 => 'Приоритет',
        _ => '?',
      };

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final layout = context.watch<VendingService>().layout;
    final storage = context.watch<DeviceStorage>();
    final globalCurtain = storage.dispenseSensorMode;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          s.t('service_test_motors').toUpperCase(),
          style: const TextStyle(
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
              fontSize: 20),
        ),
      ),
      body: Column(
        children: [
          _GlobalCurtainBar(
            curtain: globalCurtain,
            disabled: _runningSlotKey != null,
            onChanged: (v) => storage.setDispenseSensorMode(v),
            onApplyToAll: () => _applyGlobalCurtainToAll(globalCurtain),
          ),
          Expanded(
            child: layout.isEmpty
                ? const _EmptyLayoutHint()
                : _ShelvesList(
                    layout: layout,
                    runningSlotKey: _runningSlotKey,
                    results: _results,
                    resultText: _resultText,
                    savingInvIds: _savingInvIds,
                    productForSlot: _productForSlot,
                    globalCurtain: globalCurtain,
                    onRunMotor: (slot) =>
                        _runTest(slot, curtain: globalCurtain),
                    onRunCurtain: (slot) =>
                        _runTest(slot, curtain: 1),
                    onChangeMotorType: (p, t) =>
                        _patchWiring(p, motorType: t),
                    onChangeCurtain: (p, c) =>
                        _patchWiring(p, curtain: c),
                  ),
          ),
        ],
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
            const Icon(Icons.grid_off,
                size: 56, color: AppColors.onSurfaceVariant),
            const SizedBox(height: 16),
            const Text('Раскладка не настроена',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.onSurface)),
            const SizedBox(height: 8),
            const Text(
              'Откройте редактор раскладки, выберите шаблон '
              '(«Заводская 6×6» или «MP2404») и возвращайтесь сюда.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13, color: AppColors.onSurfaceVariant),
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

/// Global drop-sensor mode + "Apply to all slots" CTA. Disabled while
/// a test is mid-flight so the operator can't shift defaults while a
/// motor is already running with the previous setting.
class _GlobalCurtainBar extends StatelessWidget {
  const _GlobalCurtainBar({
    required this.curtain,
    required this.disabled,
    required this.onChanged,
    required this.onApplyToAll,
  });

  final int curtain;
  final bool disabled;
  final ValueChanged<int> onChanged;
  final VoidCallback onApplyToAll;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
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
          Text(
            'РЕЖИМ ВЫДАЧИ — ОБЩИЙ',
            style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
                color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: 0, label: Text(s.t('curtain_off'))),
              ButtonSegment(value: 1, label: Text(s.t('curtain_standard'))),
              ButtonSegment(value: 2, label: Text(s.t('curtain_priority'))),
            ],
            selected: {curtain},
            onSelectionChanged:
                disabled ? null : (set) => onChanged(set.first),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Действует на новые тесты. Кнопкой ниже — записать на все слоты.',
                  style: TextStyle(
                      fontSize: 11, color: AppColors.onSurfaceVariant),
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.done_all, size: 16),
                label: const Text('Применить ко всем'),
                onPressed: disabled ? null : onApplyToAll,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ShelvesList extends StatelessWidget {
  const _ShelvesList({
    required this.layout,
    required this.runningSlotKey,
    required this.results,
    required this.resultText,
    required this.savingInvIds,
    required this.productForSlot,
    required this.globalCurtain,
    required this.onRunMotor,
    required this.onRunCurtain,
    required this.onChangeMotorType,
    required this.onChangeCurtain,
  });

  final MachineLayout layout;
  final int? runningSlotKey;
  final Map<int, bool> results;
  final Map<int, String> resultText;
  final Set<String> savingInvIds;
  final Product? Function(Slot) productForSlot;
  final int globalCurtain;
  final ValueChanged<Slot> onRunMotor;
  final ValueChanged<Slot> onRunCurtain;
  final void Function(Product, int) onChangeMotorType;
  final void Function(Product, int) onChangeCurtain;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      itemCount: layout.shelves.length,
      itemBuilder: (_, i) {
        final shelf = layout.shelves[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
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
                          color: AppColors.onSurface),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '× ${shelf.slots.length}',
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              for (var j = 0; j < shelf.slots.length; j++) ...[
                _SlotRow(
                  slot: shelf.slots[j],
                  product: productForSlot(shelf.slots[j]),
                  running: runningSlotKey == shelf.slots[j].primaryMotorId,
                  disabledByOthers: runningSlotKey != null &&
                      runningSlotKey != shelf.slots[j].primaryMotorId,
                  saving: savingInvIds.contains(
                      productForSlot(shelf.slots[j])?.id ?? ''),
                  lastResult: results[shelf.slots[j].primaryMotorId],
                  lastResultText:
                      resultText[shelf.slots[j].primaryMotorId],
                  globalCurtain: globalCurtain,
                  onRunMotor: () => onRunMotor(shelf.slots[j]),
                  onRunCurtain: () => onRunCurtain(shelf.slots[j]),
                  onChangeMotorType: (t) {
                    final p = productForSlot(shelf.slots[j]);
                    if (p != null) onChangeMotorType(p, t);
                  },
                  onChangeCurtain: (c) {
                    final p = productForSlot(shelf.slots[j]);
                    if (p != null) onChangeCurtain(p, c);
                  },
                ),
                if (j != shelf.slots.length - 1) const SizedBox(height: 8),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// One row per slot — label/motors on the left, wiring + test controls
/// on the right. Compacts vertically on narrow screens.
class _SlotRow extends StatelessWidget {
  const _SlotRow({
    required this.slot,
    required this.product,
    required this.running,
    required this.disabledByOthers,
    required this.saving,
    required this.lastResult,
    required this.lastResultText,
    required this.globalCurtain,
    required this.onRunMotor,
    required this.onRunCurtain,
    required this.onChangeMotorType,
    required this.onChangeCurtain,
  });

  final Slot slot;
  final Product? product;
  final bool running;
  final bool disabledByOthers;
  final bool saving;
  final bool? lastResult;
  final String? lastResultText;
  final int globalCurtain;
  final VoidCallback onRunMotor;
  final VoidCallback onRunCurtain;
  final ValueChanged<int> onChangeMotorType;
  final ValueChanged<int> onChangeCurtain;

  @override
  Widget build(BuildContext context) {
    final hasProduct = product != null;
    final motorType = product?.motorType ?? 2;
    final curtain = product?.curtainMode ?? globalCurtain;
    final motorsLabel = slot.motorIds.map((m) => 'M$m').join('+');

    final Color border;
    if (running) {
      border = AppColors.primary;
    } else if (lastResult == true) {
      border = const Color(0x4D2E7D32);
    } else if (lastResult == false) {
      border = const Color(0x4DB3261E);
    } else {
      border = AppColors.surfaceContainerHigh;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border, width: 1.5),
        boxShadow: const [appCardShadow],
      ),
      child: Opacity(
        opacity: disabledByOthers ? 0.4 : 1.0,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Slot ID badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.iosBlue,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          slot.label,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                            height: 1,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          motorsLabel,
                          style: const TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: Colors.white70,
                            letterSpacing: 0.3,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (slot.isTwin)
                              Container(
                                margin: const EdgeInsets.only(right: 6),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 5, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppColors.iosOrange
                                      .withValues(alpha: 0.22),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  'TWIN',
                                  style: TextStyle(
                                      color: AppColors.iosOrange,
                                      fontSize: 8,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 1.0),
                                ),
                              ),
                            Flexible(
                              child: Text(
                                hasProduct
                                    ? product!.name
                                    : 'нет товара',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                  color: hasProduct
                                      ? AppColors.onSurface
                                      : AppColors.onSurfaceVariant,
                                  fontStyle: hasProduct
                                      ? FontStyle.normal
                                      : FontStyle.italic,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (lastResultText != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            lastResultText!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: lastResult == true
                                  ? const Color(0xFF2E7D32)
                                  : const Color(0xFFB3261E),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (saving)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              // Wiring controls
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'ТИП МОТОРА',
                          style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.0,
                              color: AppColors.onSurfaceVariant),
                        ),
                        const SizedBox(height: 4),
                        SegmentedButton<int>(
                          showSelectedIcon: false,
                          style: SegmentedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            textStyle: const TextStyle(
                                fontSize: 11, fontWeight: FontWeight.w700),
                          ),
                          segments: const [
                            ButtonSegment(value: 2, label: Text('2-провод')),
                            ButtonSegment(value: 3, label: Text('3-провод')),
                          ],
                          selected: {motorType},
                          onSelectionChanged: !hasProduct || disabledByOthers
                              ? null
                              : (set) => onChangeMotorType(set.first),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'ВЫДАЧА (СЛОТ)',
                          style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.0,
                              color: AppColors.onSurfaceVariant),
                        ),
                        const SizedBox(height: 4),
                        SegmentedButton<int>(
                          showSelectedIcon: false,
                          style: SegmentedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            textStyle: const TextStyle(
                                fontSize: 11, fontWeight: FontWeight.w700),
                          ),
                          segments: const [
                            ButtonSegment(value: 0, label: Text('off')),
                            ButtonSegment(value: 1, label: Text('on')),
                            ButtonSegment(value: 2, label: Text('prio')),
                          ],
                          selected: {curtain},
                          onSelectionChanged: !hasProduct || disabledByOthers
                              ? null
                              : (set) => onChangeCurtain(set.first),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Test buttons
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: running
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2),
                            )
                          : const Icon(Icons.precision_manufacturing,
                              size: 16),
                      label: const Text('Тест мотора'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      onPressed: disabledByOthers ? null : onRunMotor,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.sensors, size: 16),
                      label: const Text('Датчик'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        foregroundColor: Colors.lightBlue.shade700,
                        side: BorderSide(color: Colors.lightBlue.shade300),
                      ),
                      onPressed: disabledByOthers ? null : onRunCurtain,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
