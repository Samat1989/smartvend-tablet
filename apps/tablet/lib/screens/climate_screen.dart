import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/climate_config.dart';
import '../services/climate_controller.dart';
import '../services/strings.dart';

/// Minimal climate screen — only mode + temperature setpoint are user-editable.
/// All compressor safety constants are hardcoded from the factory algorithm
/// and not exposed (so the user cannot accidentally damage the compressor).
class ClimateScreen extends StatelessWidget {
  const ClimateScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    return Scaffold(
      appBar: AppBar(title: Text(s.t('climate_title'))),
      body: Consumer<ClimateController>(
        builder: (context, ctrl, _) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _statusCard(s, ctrl),
              const SizedBox(height: 16),
              _modeCard(s, ctrl),
              const SizedBox(height: 16),
              if (ctrl.config.mode != ClimateMode.off) _setpointCard(s, ctrl),
              const SizedBox(height: 16),
              _lightCard(s, ctrl),
              const SizedBox(height: 16),
              _glassHeaterCard(s, ctrl),
              const SizedBox(height: 16),
              _detailsExpansion(s, ctrl),
            ],
          );
        },
      ),
    );
  }

  // ---------- status card ----------

  Widget _statusCard(Strings s, ClimateController ctrl) {
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
              ctrl.statusMessage(s),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: Colors.black87),
            ),
            const SizedBox(height: 12),
            _phaseIndicator(s, ctrl.phase),
          ],
        ),
      ),
    );
  }

  Widget _phaseIndicator(Strings s, CompressorPhase phase) {
    final (label, color, icon) = switch (phase) {
      CompressorPhase.idle =>
        (s.t('climate_phase_idle'), Colors.grey, Icons.power_settings_new),
      CompressorPhase.warmingFan =>
        (s.t('climate_phase_fan'), Colors.orange, Icons.air),
      CompressorPhase.cooling =>
        (s.t('climate_phase_cooling'), Colors.lightBlue, Icons.ac_unit),
      CompressorPhase.resting =>
        (s.t('climate_phase_rest'), Colors.purple, Icons.bedtime),
      CompressorPhase.noProbe =>
        (s.t('climate_phase_noprobe'), Colors.red, Icons.error),
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

  Widget _modeCard(Strings s, ClimateController ctrl) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.t('climate_mode_label'),
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SegmentedButton<ClimateMode>(
              segments: ClimateMode.values
                  .map((m) =>
                      ButtonSegment(value: m, label: Text(s.t(m.labelKey))))
                  .toList(),
              selected: {ctrl.config.mode},
              onSelectionChanged: (sel) =>
                  ctrl.updateConfig(ctrl.config.copyWith(mode: sel.first)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _setpointCard(Strings s, ClimateController ctrl) {
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
                  isCooling
                      ? s.t('climate_setpoint_cool')
                      : s.t('climate_setpoint_heat'),
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
              s
                  .t(isCooling
                      ? 'climate_setpoint_hint_cool'
                      : 'climate_setpoint_hint_heat')
                  .replaceAll(
                      '%on%',
                      (cfg.setpointC + (isCooling ? 4 : -4))
                          .toStringAsFixed(1))
                  .replaceAll('%off%', cfg.setpointC.toStringAsFixed(1)),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- light + curtain ----------

  Widget _lightCard(Strings s, ClimateController ctrl) {
    return Card(
      child: SwitchListTile(
        title: Text(s.t('climate_ch_light'),
            style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.w600)),
        subtitle: Text(s.t('climate_light_hint')),
        value: ctrl.config.lightAlwaysOn,
        onChanged: (v) =>
            ctrl.updateConfig(ctrl.config.copyWith(lightAlwaysOn: v)),
      ),
    );
  }

  Widget _glassHeaterCard(Strings s, ClimateController ctrl) {
    return Card(
      child: SwitchListTile(
        title: Text(s.t('climate_glass_title'),
            style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.w600)),
        subtitle: Text(
          s.t('climate_glass_hint'),
          style: const TextStyle(fontSize: 12),
        ),
        value: ctrl.config.hasGlassHeater,
        onChanged: (v) =>
            ctrl.updateConfig(ctrl.config.copyWith(hasGlassHeater: v)),
      ),
    );
  }

  // ---------- details (collapsible) ----------

  Widget _detailsExpansion(Strings s, ClimateController ctrl) {
    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.info_outline),
        title: Text(s.t('details_more'),
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w500)),
        subtitle: Text(
          s.t('climate_details_hint'),
          style: const TextStyle(fontSize: 12),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _outputRow(s, DoChannel.fan, ctrl.fanOn),
                _outputRow(s, DoChannel.compressor, ctrl.compressorOn),
                _outputRow(s, DoChannel.glassHeater, ctrl.glassHeaterOn),
                _outputRow(s, DoChannel.lightStrip, ctrl.ledOn),
                _outputRow(s, DoChannel.heaterModule, ctrl.heaterModuleOn),
                const Divider(height: 24),
                Text(
                  s.t('climate_protect_title'),
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 12),
                ),
                const SizedBox(height: 4),
                for (var i = 1; i <= 6; i++)
                  _BulletText(s.t('climate_protect_$i')),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _outputRow(Strings s, DoChannel channel, bool on) {
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
          Expanded(child: Text(s.t(channel.labelKey))),
          Text(
            on ? s.t('climate_on') : s.t('climate_off'),
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
