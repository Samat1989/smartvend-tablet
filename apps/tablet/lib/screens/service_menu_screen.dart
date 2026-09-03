import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../board/board_client.dart';
import '../services/device_storage.dart';
import '../services/strings.dart';
import '../widgets/service_tile.dart';
import 'board_diag_screen.dart';
import 'climate_screen.dart';
import 'inventory_edit_screen.dart';
import 'layout_editor_screen.dart';
import 'screensaver_media_screen.dart';
import 'storefront_settings_screen.dart';
import 'support_settings_screen.dart';
import 'system_settings_screen.dart';
import 'tester_screen.dart';

/// Hub for service-mode actions. Reached via the long-press on the home
/// screen header → PIN gate → here.
class ServiceMenuScreen extends StatelessWidget {
  const ServiceMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    // На плате с замком половина сервисных функций физически отсутствует:
    // моторов нет, каналов DO и датчиков температуры тоже. Плитки не прячем,
    // а гасим — см. ServiceTile.disabledReason.
    final lockBoard = context.watch<BoardClient>().isMicromarket;

    return Scaffold(
      backgroundColor: Colors.grey.shade900,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(s.t('service_mode'),
            style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _StatusHeader(),
              const SizedBox(height: 16),
              Expanded(
                child: GridView.count(
                  crossAxisCount: 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.1,
                  children: [
                    ServiceTile(
                      icon: Icons.precision_manufacturing,
                      label: s.t('service_test_motors'),
                      color: Colors.indigo,
                      disabledReason: lockBoard ? s.t('tile_off_no_motors') : null,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const TesterScreen()),
                      ),
                    ),
                    ServiceTile(
                      icon: Icons.thermostat,
                      label: s.t('service_climate'),
                      color: Colors.lightBlue,
                      // На релейной плате нет каналов DO и датчиков: writeDo и
                      // readTemp в этом режиме возвращают «не поддерживается»,
                      // так что экран климата управлял бы пустотой.
                      disabledReason: lockBoard ? s.t('tile_off_no_channels') : null,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const ClimateScreen()),
                      ),
                    ),
                    ServiceTile(
                      icon: Icons.inventory_2,
                      label: s.t('service_inventory'),
                      color: Colors.teal,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const InventoryEditScreen()),
                      ),
                    ),
                    // «Раскладка каталога» was a placeholder that only ever
                    // showed a "в разработке" dialog. Its job is now split
                    // for real between «Витрина» (how the catalog looks) and
                    // «Редактор раскладки» (which motor sits where).
                    ServiceTile(
                      icon: Icons.dashboard_customize,
                      label: s.t('service_layout_editor'),
                      color: Colors.indigo,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const LayoutEditorScreen()),
                      ),
                    ),
                    ServiceTile(
                      icon: Icons.storefront,
                      label: s.t('service_storefront'),
                      color: Colors.cyan.shade700,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const StorefrontSettingsScreen()),
                      ),
                    ),
                    ServiceTile(
                      icon: Icons.slideshow,
                      label: s.t('service_screensaver_media'),
                      color: Colors.pink,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const ScreensaverMediaScreen()),
                      ),
                    ),
                    ServiceTile(
                      icon: Icons.support_agent,
                      label: s.t('service_support'),
                      color: Colors.green.shade700,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const SupportSettingsScreen()),
                      ),
                    ),
                    // Sensor mode picker moved into the inventory screen.
                    // The operator manages slot-level concerns there, and
                    // sensor mode is one of them — keeps service-menu
                    // focused on machine-wide settings (PIN, layout, etc).
                    ServiceTile(
                      icon: Icons.developer_board,
                      label: s.t('service_board'),
                      color: Colors.purple,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const BoardDiagScreen()),
                      ),
                    ),
                    // No manual "Обновить" tile: VendingService already
                    // re-fetches the catalog every 60 s (see
                    // _startAutoRefresh), skipping only while a customer has
                    // items in the cart. A button that just races that timer
                    // gave the operator nothing and crowded the menu. The
                    // error screen still offers a retry.
                    //
                    // Всё, что про сам планшет, а не про автомат —
                    // обновление, PIN, полосы, перезагрузка, выход в Android
                    // и отвязка — уехало на отдельный экран. В плоском гриде
                    // их стало четырнадцать, и техник, искавший «Обновление»,
                    // читал мимо тестов моторов.
                    ServiceTile(
                      icon: Icons.settings,
                      label: s.t('service_system'),
                      color: Colors.blueGrey,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const SystemSettingsScreen()),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact diagnostic strip shown above the service-menu tiles. Surfaces
/// the three things an operator needs to see at a glance: which machine
/// they're servicing, whether the M102 board is responding, and what
/// firmware that board reports. The firmware ID is queried lazily on
/// connect by [BoardClient._refreshFirmwareId] and is null until either
/// the probe completes or another command succeeds.
class _StatusHeader extends StatelessWidget {
  const _StatusHeader();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final storage = context.watch<DeviceStorage>();
    final board = context.watch<BoardClient>();
    final connected = board.isConnected;
    final healthy = board.isHealthy;
    final fwId = board.firmwareId;

    final Color statusColor;
    final String statusLabel;
    // Тот же порядок веток, что и на экране «Плата»: режим важнее связи,
    // потому что связи в нём нет по замыслу — см. _StatusCard там.
    if (board.isStandaloneLock) {
      statusColor = Colors.blueGrey;
      statusLabel = s.t('board_status_standalone');
    } else if (!connected) {
      statusColor = Colors.redAccent;
      statusLabel = s.t('board_connect');
    } else if (!healthy) {
      statusColor = Colors.orange;
      statusLabel = s.t('board_health_lost');
    } else {
      statusColor = Colors.greenAccent;
      statusLabel = s.t('board_health_ok');
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (storage.machid != null)
            Row(
              children: [
                const Icon(Icons.qr_code_2,
                    color: Colors.white70, size: 18),
                const SizedBox(width: 10),
                Text(
                  '${s.t('service_machine_id')}${storage.machid}',
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ],
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${s.t('board_status')}: $statusLabel',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9), fontSize: 13),
              ),
            ],
          ),
          if (fwId != null) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 20),
              child: Text(
                '${s.t('board_firmware')}: $fwId',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6), fontSize: 11),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
