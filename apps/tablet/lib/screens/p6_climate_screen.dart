import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../board/board_client.dart';
import '../services/strings.dart';

/// Холодильник платы P6-LZ: режим и уставка. Термостат крутит демон на самой
/// плате, планшет только задаёт режим (1 — охлаждение, 3 — выкл) и целую
/// уставку и показывает то, что плата хранит, и текущую температуру в салоне
/// (`CLIMATE TEMP`, её отдаёт плата из ответа демона).
class P6ClimateScreen extends StatefulWidget {
  const P6ClimateScreen({super.key});

  @override
  State<P6ClimateScreen> createState() => _P6ClimateScreenState();
}

class _P6ClimateScreenState extends State<P6ClimateScreen> {
  static const double _min = 0;
  static const double _max = 15;

  bool _cool = true;
  double _setpoint = 5;
  int? _boardMode;
  int? _boardSetpoint;
  double? _temp;
  bool _answered = true;
  bool _busy = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh(adopt: true);
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// [adopt] — при первом чтении подставить в элементы управления то, что
  /// сейчас стоит на плате, чтобы не показывать выдуманные значения.
  Future<void> _refresh({bool adopt = false}) async {
    if (_busy) return;
    final board = context.read<BoardClient>();
    final st = await board.climateState();
    final temp = st == null ? null : await board.climateTemp();
    if (!mounted) return;
    setState(() {
      _answered = st != null;
      _boardMode = st?.mode;
      _boardSetpoint = st?.setpoint;
      _temp = temp;
      if (adopt && st != null) {
        if (st.mode != null) _cool = st.mode == 1;
        final sp = st.setpoint;
        if (sp != null && sp >= _min && sp <= _max) _setpoint = sp.toDouble();
      }
    });
  }

  Future<void> _apply() async {
    final s = context.read<Strings>();
    final board = context.read<BoardClient>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final ok = _cool
        ? await board.setClimateSetpoint(_setpoint)
        : await board.climateOff();
    if (!mounted) return;
    setState(() => _busy = false);
    messenger.showSnackBar(SnackBar(
      content: Text(ok ? s.t('fridge_applied') : s.t('fridge_failed')),
      backgroundColor: ok ? Colors.green : Colors.redAccent,
    ));
    // демон перезапускается — дать ему подняться и перечитать состояние
    await Future<void>.delayed(const Duration(seconds: 4));
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    return Scaffold(
      appBar: AppBar(title: Text(s.t('service_climate'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _stateCard(s),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<bool>(
                    segments: [
                      ButtonSegment(
                          value: true,
                          icon: const Icon(Icons.ac_unit),
                          label: Text(s.t('fridge_mode_cool'))),
                      ButtonSegment(
                          value: false,
                          icon: const Icon(Icons.power_settings_new),
                          label: Text(s.t('fridge_mode_off'))),
                    ],
                    selected: {_cool},
                    onSelectionChanged:
                        _busy ? null : (v) => setState(() => _cool = v.first),
                  ),
                  if (_cool) ...[
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Text(s.t('fridge_setpoint'),
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600)),
                        const Spacer(),
                        Text('${_setpoint.round()} °C',
                            style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: Colors.indigo)),
                      ],
                    ),
                    Slider(
                      min: _min,
                      max: _max,
                      divisions: (_max - _min).round(),
                      value: _setpoint,
                      label: '${_setpoint.round()} °C',
                      onChanged:
                          _busy ? null : (v) => setState(() => _setpoint = v),
                    ),
                  ],
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _busy ? null : _apply,
                      child: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(s.t('fridge_apply')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stateCard(Strings s) {
    final String mode;
    if (!_answered) {
      mode = s.t('fridge_no_answer');
    } else if (_boardMode == null) {
      mode = '—';
    } else {
      mode = _boardMode == 1 ? s.t('fridge_mode_cool') : s.t('fridge_mode_off');
    }
    final sp = (_answered && _boardMode == 1 && _boardSetpoint != null)
        ? ' • ${_boardSetpoint!} °C'
        : '';
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: Icon(Icons.device_thermostat,
                color: _temp != null ? Colors.lightBlue : Colors.grey),
            title: Text(s.t('fridge_current')),
            subtitle: _answered && _temp == null
                ? Text(s.t('fridge_no_temp'))
                : null,
            trailing: Text(
                _temp == null ? '— °C' : '${_temp!.toStringAsFixed(1)} °C',
                style: const TextStyle(
                    fontSize: 28, fontWeight: FontWeight.bold)),
          ),
          ListTile(
            leading: Icon(Icons.thermostat,
                color: _answered ? Colors.lightBlue : Colors.red),
            title: Text(s.t('fridge_state')),
            subtitle: Text('$mode$sp', style: const TextStyle(fontSize: 18)),
          ),
        ],
      ),
    );
  }
}
