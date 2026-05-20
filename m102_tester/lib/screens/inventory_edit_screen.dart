import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/motor_layout.dart';
import '../models/product.dart';
import '../services/device_storage.dart';
import '../services/strings.dart';
import '../services/vending_service.dart';
import '../theme.dart';
import 'product_edit_screen.dart';

/// Service-mode tool: vertical list of all 36 motor slots, one row per slot.
/// Each row exposes every per-slot setting at a glance (name, price, stock,
/// motor type, drop-sensor mode) so the operator doesn't need to open the
/// detail form just to check what's configured.
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
          final motors = MotorLayout.allMotors().toList();
          return Column(
            children: [
              const _SensorModeHeader(),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: motors.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final motorId = motors[i];
                    final product = byMotor[motorId];
                    return _ProductRow(motorId: motorId, product: product);
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
  const _ProductRow({required this.motorId, required this.product});

  final int motorId;
  final Product? product;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final shelf = MotorLayout.motorToLabel(motorId);
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
                motorId: motorId,
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
              _slotBadge(shelf, motorId),
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

  Widget _slotBadge(String shelf, int motor) {
    return Container(
      width: 56,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: Colors.indigo.shade50,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Text(
            shelf,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Colors.indigo.shade700,
            ),
          ),
          Text(
            'M$motor',
            style: TextStyle(
              fontSize: 10,
              color: Colors.grey.shade500,
            ),
          ),
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
