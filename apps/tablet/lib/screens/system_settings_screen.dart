import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/device_storage.dart';
import '../services/kiosk_bridge.dart';
import '../services/app_error.dart';
import '../services/strings.dart';
import '../widgets/error_card.dart';
import '../services/supabase_api.dart';
import '../widgets/service_tile.dart';
import 'update_screen.dart';

/// Everything in service mode that is about the *tablet* rather than the
/// machine: the app version, the way out to Android, the system bars, the
/// PIN that guards all of it, and the two ways of ending a session — a
/// reboot or giving the machine up entirely.
///
/// Split out because the flat service menu had grown to fourteen tiles, and
/// an operator hunting for «Обновление» was reading past motor tests to find
/// it. The line is drawn by subject, not by frequency: what is in front of
/// the technician (моторы, товар, витрина, плата) stays on the first screen,
/// what is underneath it comes here.
///
/// Ordered from routine to irreversible, so the two actions that end
/// something — leaving the kiosk, unpairing the machine — sit at the bottom
/// where a misplaced tap is least likely to land.
class SystemSettingsScreen extends StatefulWidget {
  const SystemSettingsScreen({super.key});

  @override
  State<SystemSettingsScreen> createState() => _SystemSettingsScreenState();
}

class _SystemSettingsScreenState extends State<SystemSettingsScreen> {
  /// What the tablet under us can actually do. Starts at
  /// [KioskCapabilities.unknown], which greys out the firmware-specific
  /// tiles — the honest state while we do not know yet, and the final state
  /// on a tablet from another supplier. Resolves from the bridge's cache in
  /// milliseconds on every visit after the first.
  KioskCapabilities _caps = KioskCapabilities.unknown;

  @override
  void initState() {
    super.initState();
    KioskBridge.capabilities().then((c) {
      if (mounted) setState(() => _caps = c);
    });
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
        title: Text(s.t('service_system'),
            style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Which tablet this is, in the operator's own words. Saves a
              // trip into Android Settings when someone on the phone asks
              // "а какой у тебя планшет?" — and explains at a glance why the
              // greyed-out tiles below are greyed out.
              if (_caps.firmware.isNotEmpty) ...[
                Text(
                  _caps.firmware,
                  style: const TextStyle(
                      color: Colors.white38, fontSize: 11, height: 1.4),
                ),
                const SizedBox(height: 12),
              ],
              Expanded(
                child: GridView.count(
                  crossAxisCount: 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.1,
                  children: [
                    ServiceTile(
                      icon: Icons.system_update,
                      label: s.t('service_update'),
                      color: Colors.deepOrange,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const UpdateScreen()),
                      ),
                    ),
                    ServiceTile(
                      icon: Icons.password,
                      label: s.t('service_change_pin'),
                      color: Colors.amber.shade800,
                      onTap: () => _changePin(context),
                    ),
                    // Системными полосами на этих автоматах распоряжается
                    // прошивка, а не приложение. На планшете другого
                    // поставщика кнопке нечего дёргать — гасим и говорим
                    // почему, см. docs/05_SYSTEM_BARS_AND_AUTOSTART.md.
                    ServiceTile(
                      icon: Icons.smart_button,
                      label: s.t('service_show_navbar'),
                      color: Colors.teal,
                      disabledReason:
                          _caps.vendorBars ? null : s.t('tile_off_vendor_only'),
                      onTap: () => _showNavBar(context),
                    ),
                    // Перезагрузить умеем двумя путями: правами владельца
                    // устройства или broadcast'ом прошивки. Нет ни одного —
                    // остаётся только выключить питание руками.
                    ServiceTile(
                      icon: Icons.restart_alt,
                      label: s.t('service_reboot'),
                      color: Colors.indigo,
                      disabledReason:
                          _caps.canReboot ? null : s.t('tile_off_needs_owner'),
                      onTap: () => _rebootDevice(context),
                    ),
                    ServiceTile(
                      icon: Icons.exit_to_app,
                      label: s.t('service_exit_kiosk'),
                      color: Colors.blueGrey,
                      onTap: () => _exitToAndroid(context),
                    ),
                    ServiceTile(
                      icon: Icons.logout,
                      label: s.t('service_unpair'),
                      color: Colors.redAccent,
                      onTap: () => _confirmUnpair(context),
                    ),
                    // Единственный способ снять права с обычной сборки:
                    // `dpm remove-active-admin` отказывается трогать
                    // не-test-only владельца, а заводской сброс уносит с
                    // собой Wi-Fi, отладку и ключ adb. Нужно при переезде
                    // планшета на другой аппарат — пока приложение владеет
                    // устройством, его нельзя даже удалить.
                    ServiceTile(
                      icon: Icons.admin_panel_settings,
                      label: s.t('service_clear_owner'),
                      color: Colors.red.shade700,
                      disabledReason:
                          _caps.deviceOwner ? null : s.t('tile_off_no_owner'),
                      onTap: () => _clearDeviceOwner(context),
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

  /// Change the service PIN — typed twice, and the dialog will not close
  /// until both boxes agree and the PIN passes [DeviceStorage.validatePin].
  ///
  /// The confirmation is not ceremony. This PIN is the only way back into
  /// service mode, the tablet is device owner so there is no uninstalling
  /// around it, and the field is obscured — a single typo committed here
  /// would leave the operator standing at a cabinet they can no longer get
  /// into. Same reason the first-run screen has always asked twice; this
  /// entry point simply never did.
  Future<void> _changePin(BuildContext context) async {
    final s = context.read<Strings>();
    final ctrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) {
        String? error;
        return StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            title: Text(s.t('service_change_pin')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.t('pin_change_hint'),
                  style: const TextStyle(
                      fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 8,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(labelText: s.t('pin_new')),
                ),
                TextField(
                  controller: confirmCtrl,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 8,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(labelText: s.t('pin_repeat')),
                ),
                if (error != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    error!,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFB3261E)),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(s.t('btn_cancel')),
              ),
              FilledButton(
                onPressed: () {
                  final entered = ctrl.text.trim();
                  final reason = DeviceStorage.validatePin(entered);
                  if (reason != null) {
                    setLocal(() => error = s
                        .t(reason)
                        .replaceAll('%n%', '${DeviceStorage.minPinLength}'));
                    return;
                  }
                  if (entered != confirmCtrl.text.trim()) {
                    setLocal(() => error = s.t('pin_mismatch'));
                    return;
                  }
                  Navigator.of(ctx).pop(entered);
                },
                child: Text(s.t('btn_save')),
              ),
            ],
          ),
        );
      },
    );
    if (pin == null || !context.mounted) return;
    await context.read<DeviceStorage>().setServicePin(pin);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(context.read<Strings>().t('pin_changed')),
          backgroundColor: Colors.green),
    );
  }

  /// Turn the Android navigation and status bars back on and reboot into
  /// them — the servicing equivalent of the factory app's own switch.
  ///
  /// The confirmation is worth its keystroke: this reboots the tablet on
  /// the spot, and on a machine that is mid-sale that is not something to
  /// discover after the fact. The dialog also says the quiet part out
  /// loud — the bars last one session and the next reboot takes them
  /// away again — because an operator who does not know that will come
  /// back looking for a switch to turn off.
  Future<void> _showNavBar(BuildContext context) async {
    final s = context.read<Strings>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('service_show_navbar')),
        content: Text(s.t('service_show_navbar_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.t('payment_cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(s.t('service_show_navbar_go')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await KioskBridge.showNavBarAndReboot();
    } catch (e) {
      if (context.mounted) {
        showErrorSnack(context, AppError.from(e)..log('SystemSettings.reboot'));
      }
    }
  }

  /// Restart the whole tablet from the service menu.
  ///
  /// The plain reboot, with none of the property juggling [_showNavBar]
  /// does — for when the board has gone quiet, an update wants a clean
  /// start, or the operator simply wants the machine to come up fresh
  /// before leaving the site. [KioskBridge.rebootDevice] finds a way on
  /// its own: device owner if we have it, the RY firmware broadcast if we
  /// do not.
  ///
  /// If neither path exists the native side throws, and rather than leave
  /// the operator guessing whether the tap registered, we say so and offer
  /// nothing — a tablet that cannot reboot itself needs the power switch.
  Future<void> _rebootDevice(BuildContext context) async {
    final s = context.read<Strings>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('service_reboot')),
        content: Text(s.t('service_reboot_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.t('payment_cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(s.t('service_reboot')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await KioskBridge.rebootDevice();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.t('service_reboot_failed'))),
        );
      }
    }
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
        showErrorSnack(context, AppError.from(e)..log('SystemSettings.reboot'));
      }
    }
  }

  /// Give up device-owner rights.
  ///
  /// Asked twice over, because this is the one action on the screen the
  /// tablet cannot undo by itself: getting the rights back means adb or
  /// mmd_diag on a device with no accounts, which is a trip to the machine.
  /// In exchange it is the only way to free a release build short of a
  /// factory reset — the app cannot even be uninstalled while it owns the
  /// device.
  ///
  /// Kiosk protection stops immediately: no more silent lock task, and the
  /// notification shade comes back. On tablets whose firmware hides the
  /// system bars that is survivable; anywhere else the machine is open until
  /// it is provisioned again.
  Future<void> _clearDeviceOwner(BuildContext context) async {
    final s = context.read<Strings>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('service_clear_owner')),
        content: Text(s.t('service_clear_owner_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.t('payment_cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(s.t('service_clear_owner_go')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await KioskBridge.clearDeviceOwner();
      final fresh = await KioskBridge.capabilities();
      if (!mounted) return;
      setState(() => _caps = fresh);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(s.t('service_clear_owner_done')),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        showErrorSnack(context, AppError.from(e)..log('SystemSettings.reboot'));
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
        // Пробрасываем до самого низа стека: под нами ещё и сервисное меню,
        // которое после сброса привязки показывало бы чужой аппарат.
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
    }
  }
}
