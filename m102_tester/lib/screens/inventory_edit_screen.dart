import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/machine_layout.dart';
import '../models/product.dart';
import '../services/device_storage.dart';
import '../services/strings.dart';
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
/// Products are still keyed in the catalog by single motor id
/// ([Product.motorId]), so we look each row's product up via the
/// slot's [Slot.primaryMotorId]. Twin/wide-spiral slots show every
/// motor id in the badge.
class InventoryEditScreen extends StatelessWidget {
  const InventoryEditScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      appBar: AppBar(
        title: Text(s.t('inv_grid_title')),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: s.t('reload'),
            onPressed: () => context.read<VendingService>().reload(),
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
                    return _ShelfBlock(shelf: shelf, byMotor: byMotor);
                  },
                ),
              ),
            ],
          );
        },
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
  const _ShelfBlock({required this.shelf, required this.byMotor});

  final Shelf shelf;
  final Map<int, Product> byMotor;

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
              _ProductRow(
                slot: shelf.slots[i],
                product: byMotor[shelf.slots[i].primaryMotorId],
              ),
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
  const _ProductRow({required this.slot, required this.product});

  final Slot slot;
  final Product? product;

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
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ProductEditScreen(
                motorId: slot.primaryMotorId,
                existing: product,
              ),
            ),
          );
          if (context.mounted) {
            await context.read<VendingService>().reload();
          }
        },
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
              Icon(
                empty ? Icons.add_circle_outline : Icons.edit_outlined,
                color: empty ? Colors.grey.shade400 : Colors.indigo.shade300,
                size: 22,
              ),
            ],
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
        child: Image.network(
          url,
          width: 44,
          height: 44,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _emojiBox(p.emoji),
          loadingBuilder: (_, child, progress) =>
              progress == null ? child : _emojiBox(p.emoji),
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
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            _chip(
              icon: Icons.payments_outlined,
              label: '${p.priceTenge} ${s.t('currency')}',
              color: Colors.indigo,
            ),
            _chip(
              icon: Icons.inventory_2_outlined,
              label: '×${p.stock}',
              color: p.stock > 0 ? Colors.green.shade700 : Colors.red,
            ),
            _chip(
              icon: Icons.cable_outlined,
              label: p.motorType == 3
                  ? s.t('motor_type_3')
                  : s.t('motor_type_2'),
              color: Colors.grey.shade700,
            ),
            _chip(
              icon: Icons.sensors,
              label: switch (p.curtainMode) {
                1 => s.t('curtain_standard'),
                2 => s.t('curtain_priority'),
                _ => s.t('curtain_off'),
              },
              color: p.curtainMode == 0
                  ? Colors.grey.shade500
                  : Colors.lightBlue.shade700,
            ),
          ],
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
