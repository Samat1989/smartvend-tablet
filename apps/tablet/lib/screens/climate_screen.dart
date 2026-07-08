import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/climate_config.dart';
import '../services/climate_controller.dart';

/// Minimal climate screen — only mode + temperature setpoint are user-editable.
/// All compressor safety constants are hardcoded from the factory algorithm
/// and not exposed (so the user cannot accidentally damage the compressor).
class ClimateScreen extends StatelessWidget {
  const ClimateScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Климат')),
      body: Consumer<ClimateController>(
        builder: (context, ctrl, _) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _statusCard(ctrl),
              const SizedBox(height: 16),
              _modeCard(ctrl),
              const SizedBox(height: 16),
              if (ctrl.config.mode != ClimateMode.off) _setpointCard(ctrl),
              const SizedBox(height: 16),
              _lightCard(ctrl),
              const SizedBox(height: 16),
              _glassHeaterCard(ctrl),
              const SizedBox(height: 16),
              _detailsExpansion(ctrl),
            ],
          );
        },
      ),
    );
  }

  // ---------- status card ----------

  Widget _statusCard(ClimateController ctrl) {
    final t = ctrl.temperatureC;
    final h = ctrl.humidityPercent;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t == null ? '— °C' : '${t.toStringAsFixed(1)}°C',
                  style: const TextStyle(
                      fontSize: 56, fontWeight: FontWeight.bold, color: Colors.indigo),
                ),
                if (h != null) ...[
                  const SizedBox(width: 16),
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      '$h %',
                      style: TextStyle(fontSize: 28, color: Colors.teal.shade700),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(
              ctrl.statusMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: Colors.black87),
            ),
            const SizedBox(height: 12),
            _phaseIndicator(ctrl.phase),
          ],
        ),
      ),
    );
  }

  Widget _phaseIndicator(CompressorPhase phase) {
    final (label, color, icon) = switch (phase) {
      CompressorPhase.idle => ('Простой', Colors.grey, Icons.power_settings_new),
      CompressorPhase.warmingFan => ('Продувка вентилятором', Colors.orange, Icons.air),
      CompressorPhase.cooling => ('Компрессор работает', Colors.lightBlue, Icons.ac_unit),
      CompressorPhase.resting => ('Принудительный отдых', Colors.purple, Icons.bedtime),
      CompressorPhase.noProbe => ('Нет датчика температуры', Colors.red, Icons.error),
    };
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
      ],
    );
  }

  // ---------- mode + setpoint ----------

  Widget _modeCard(ClimateController ctrl) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Режим',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SegmentedButton<ClimateMode>(
              segments: ClimateMode.values
                  .map((m) => ButtonSegment(value: m, label: Text(m.label)))
                  .toList(),
              selected: {ctrl.config.mode},
              onSelectionChanged: (s) =>
                  ctrl.updateConfig(ctrl.config.copyWith(mode: s.first)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _setpointCard(ClimateController ctrl) {
    final cfg = ctrl.config;
    final isCooling = cfg.mode == ClimateMode.cooling;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  isCooling ? 'Целевая температура (холод)' : 'Целевая температура (нагрев)',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  '${cfg.setpointC.toStringAsFixed(1)} °C',
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.bold, color: Colors.indigo),
                ),
              ],
            ),
            Builder(builder: (_) {
              final double min = isCooling ? 6 : 15;
              final double max = isCooling ? 10 : 35;
              // Defensive clamp — ClimateController.updateConfig also
              // clamps when mode changes, but if a stale persisted
              // value lands here before that runs we don't want the
              // Slider to assert and bring the screen down.
              final double v = cfg.setpointC.clamp(min, max);
              return Slider(
                min: min,
                max: max,
                divisions: isCooling ? 8 : 40,
                value: v,
                label: '${v.toStringAsFixed(1)} °C',
                onChanged: (n) => ctrl.updateConfig(cfg.copyWith(setpointC: n)),
              );
            }),
            Text(
              isCooling
                  ? 'Компрессор включится при ${(cfg.setpointC + 4).toStringAsFixed(1)} °C, '
                      'выключится при ${cfg.setpointC.toStringAsFixed(1)} °C.'
                  : 'Нагрев включится при ${(cfg.setpointC - 4).toStringAsFixed(1)} °C, '
                      'выключится при ${cfg.setpointC.toStringAsFixed(1)} °C.',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- light + curtain ----------

  Widget _lightCard(ClimateController ctrl) {
    return Card(
      child: SwitchListTile(
        title: const Text('Подсветка',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        subtitle: const Text('LED-лента в витрине'),
        value: ctrl.config.lightAlwaysOn,
        onChanged: (v) =>
            ctrl.updateConfig(ctrl.config.copyWith(lightAlwaysOn: v)),
      ),
    );
  }

  Widget _glassHeaterCard(ClimateController ctrl) {
    return Card(
      child: SwitchListTile(
        title: const Text('Подогрев стекла подключён',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        subtitle: const Text(
          'Выключите, если на этой машине реле есть, '
          'а нагревателя физически нет',
          style: TextStyle(fontSize: 12),
        ),
        value: ctrl.config.hasGlassHeater,
        onChanged: (v) =>
            ctrl.updateConfig(ctrl.config.copyWith(hasGlassHeater: v)),
      ),
    );
  }

  // ---------- details (collapsible) ----------

  Widget _detailsExpansion(ClimateController ctrl) {
    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.info_outline),
        title: const Text('Подробнее',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
        subtitle: const Text(
          'Состояние реле, защита компрессора',
          style: TextStyle(fontSize: 12),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _outputRow('Вентилятор', ctrl.fanOn),
                _outputRow('Компрессор', ctrl.compressorOn),
                _outputRow('Подогрев стекла', ctrl.glassHeaterOn),
                _outputRow('Подсветка', ctrl.ledOn),
                _outputRow('Нагревательный модуль', ctrl.heaterModuleOn),
                const Divider(height: 24),
                const Text(
                  'Защита компрессора (по заводскому алгоритму):',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                ),
                const SizedBox(height: 4),
                const _BulletText('Гистерезис ±4°C — без частых пусков-остановок'),
                const _BulletText(
                    'Продувка вентилятором 5 мин при первом запуске, потом 2 мин'),
                const _BulletText('Продувка перед нагревателем 2 мин'),
                const _BulletText('При >60 мин непрерывной работы — отдых 5 мин'),
                const _BulletText('При потере датчика — компрессор сразу ВЫКЛ'),
                const _BulletText('Компрессор не стартует, если вентилятор выключен'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _outputRow(String label, bool on) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: on ? Colors.green : Colors.grey.shade400,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
          Text(
            on ? 'ВКЛ' : 'выкл',
            style: TextStyle(
              color: on ? Colors.green.shade700 : Colors.grey,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _BulletText extends StatelessWidget {
  final String text;
  const _BulletText(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, top: 2),
      child: Text('• $text', style: const TextStyle(fontSize: 12)),
    );
  }
}

// _CurtainCard was removed — drop-sensor mode now lives in the service
// menu under «Режим выдачи» as a global app-wide setting persisted in
// DeviceStorage. The climate screen is for fridge/heating loop only.
