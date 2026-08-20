import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../board/board_client.dart';
import '../services/device_storage.dart';
import '../services/kiosk_bridge.dart';
import '../services/strings.dart';
import '../services/supabase_api.dart';
import 'board_diag_screen.dart';
import 'climate_screen.dart';
import 'inventory_edit_screen.dart';
import 'layout_editor_screen.dart';
import 'screensaver_media_screen.dart';
import 'storefront_settings_screen.dart';
import 'support_settings_screen.dart';
import 'tester_screen.dart';
import 'update_screen.dart';

/// Hub for service-mode actions. Reached via the long-press on the home
/// screen header → PIN gate → here.
class ServiceMenuScreen extends StatelessWidget {
  const ServiceMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    // На плате с замком половина сервисных функций физически отсутствует:
    // моторов нет, каналов DO и датчиков температуры тоже. Плитки не прячем,
    // а гасим — см. _Tile.disabledReason.
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
                    _Tile(
                      icon: Icons.precision_manufacturing,
                      label: s.t('service_test_motors'),
                      color: Colors.indigo,
                      disabledReason: lockBoard ? 'нет моторов' : null,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const TesterScreen()),
                      ),
                    ),
                    _Tile(
                      icon: Icons.thermostat,
                      label: s.t('service_climate'),
                      color: Colors.lightBlue,
                      // На релейной плате нет каналов DO и датчиков: writeDo и
                      // readTemp в этом режиме возвращают «не поддерживается»,
                      // так что экран климата управлял бы пустотой.
                      disabledReason: lockBoard ? 'нет каналов' : null,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const ClimateScreen()),
                      ),
                    ),
                    _Tile(
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
                    _Tile(
                      icon: Icons.dashboard_customize,
                      label: s.t('service_layout_editor'),
                      color: Colors.indigo,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const LayoutEditorScreen()),
                      ),
                    ),
                    _Tile(
                      icon: Icons.storefront,
                      label: s.t('service_storefront'),
                      color: Colors.cyan.shade700,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const StorefrontSettingsScreen()),
                      ),
                    ),
                    _Tile(
                      icon: Icons.slideshow,
                      label: s.t('service_screensaver_media'),
                      color: Colors.pink,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const ScreensaverMediaScreen()),
                      ),
                    ),
                    _Tile(
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
                    _Tile(
                      icon: Icons.password,
                      label: s.t('service_change_pin'),
                      color: Colors.amber.shade800,
                      onTap: () => _changePin(context),
                    ),
                    _Tile(
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
                    _Tile(
                      icon: Icons.system_update,
                      label: 'Обновление',
                      color: Colors.deepOrange,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const UpdateScreen()),
                      ),
                    ),
                    _Tile(
                      icon: Icons.exit_to_app,
                      label: s.t('service_exit_kiosk'),
                      color: Colors.blueGrey,
                      onTap: () => _exitToAndroid(context),
                    ),
                    _Tile(
                      icon: Icons.logout,
                      label: s.t('service_unpair'),
                      color: Colors.redAccent,
                      onTap: () => _confirmUnpair(context),
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

  Future<void> _changePin(BuildContext context) async {
    final s = context.read<Strings>();
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('service_change_pin')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 8,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(labelText: s.t('enter_pin')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.t('payment_cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(s.t('connect_btn')),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final pin = ctrl.text.trim();
    final reason = DeviceStorage.validatePin(pin);
    if (reason != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(reason), backgroundColor: Colors.redAccent),
      );
      return;
    }
    await context.read<DeviceStorage>().setServicePin(pin);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('PIN изменён'), backgroundColor: Colors.green),
    );
  }

  /// Pops a confirmation, then calls into the Android side to stop lock
  /// task and launch system Settings. The app reverts to kiosk on its
  /// next resume — operator never has to "turn kiosk back on".
  Future<void> _exitToAndroid(BuildContext context) async {
    final s = context.read<Strings>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('service_exit_kiosk')),
        content: Text(s.t('service_exit_kiosk_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.t('payment_cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(s.t('service_exit_kiosk')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await KioskBridge.exitToAndroid();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    }
  }

  Future<void> _confirmUnpair(BuildContext context) async {
    final s = context.read<Strings>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('service_unpair')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${s.t('service_machine_id')}'
                '${context.read<DeviceStorage>().machid ?? '?'}'),
            const SizedBox(height: 10),
            Text(s.t('service_unpair_hint'),
                style: const TextStyle(fontSize: 13, height: 1.35)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.t('payment_cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(s.t('service_unpair')),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      // Give the machine up before wiping the credentials — afterwards we
      // no longer have the secret to prove we were the holder, and the
      // owner would have to unbind from the panel to free it.
      final storage = context.read<DeviceStorage>();
      final machid = storage.machid;
      final secret = storage.secret;
      if (machid != null && secret != null) {
        await SupabaseApi().releaseMachine(
          machid: machid,
          secret: secret,
          deviceId: await storage.deviceId(),
        );
      }
      await storage.clearPairing();
      if (context.mounted) {
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
    }
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
    if (!connected) {
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

class _Tile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  /// Причина, по которой плитка неактивна. Null — плитка работает.
  ///
  /// Выключаем, а не прячем: у пропавшей плитки нет объяснения, и техник на
  /// точке будет искать её в обновлении или в другой прошивке. Серая плитка с
  /// подписью «нет моторов на этой плате» отвечает на вопрос сразу.
  final String? disabledReason;

  const _Tile({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.disabledReason,
  });

  @override
  Widget build(BuildContext context) {
    final off = disabledReason != null;
    final tint = off ? Colors.grey : color;
    return Material(
      color: tint.withValues(alpha: off ? 0.08 : 0.15),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: off ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: off ? Colors.white24 : color, size: 36),
              const SizedBox(height: 12),
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: off ? Colors.white38 : Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600),
              ),
              if (off) ...[
                const SizedBox(height: 4),
                Text(
                  disabledReason!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white24, fontSize: 11),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
