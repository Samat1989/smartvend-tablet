/// Output channel mapping on the M102 board (DO command 0x08).
/// Fixed by the factory firmware — do not change.
enum DoChannel {
  fan(0, 'Вентилятор'),
  compressor(1, 'Компрессор'),
  glassHeater(2, 'Подогрев стекла'),
  lightStrip(3, 'Подсветка'),
  heaterModule(4, 'Нагревательный модуль');

  final int id;
  final String label;
  const DoChannel(this.id, this.label);
}

enum ClimateMode {
  off('Выкл'),
  cooling('Холодильник'),
  heating('Нагрев'),
  ;

  final String label;
  const ClimateMode(this.label);
}

/// User-facing climate configuration. Only mode + setpoint are exposed —
/// safety constants (hysteresis, spin-up debounce, forced-rest) are baked
/// into the controller from the factory algorithm and are not user-tunable.
class ClimateConfig {
  final ClimateMode mode;
  final double setpointC;
  final bool lightAlwaysOn;
  /// Whether this cabinet has a glass-heater (anti-fog) element wired to
  /// DO #2. Default true because the factory cooler ships with one; set
  /// false from the climate screen for machines where the relay exists
  /// but no heater is physically attached — keeps that relay idle so it
  /// doesn't fire alongside the compressor (which can brown-out the USB
  /// bus and trigger the BoardClient self-heal cascade).
  final bool hasGlassHeater;

  const ClimateConfig({
    this.mode = ClimateMode.cooling,
    this.setpointC = 6.0,
    this.lightAlwaysOn = true,
    this.hasGlassHeater = true,
  });

  ClimateConfig copyWith({
    ClimateMode? mode,
    double? setpointC,
    bool? lightAlwaysOn,
    bool? hasGlassHeater,
  }) =>
      ClimateConfig(
        mode: mode ?? this.mode,
        setpointC: setpointC ?? this.setpointC,
        lightAlwaysOn: lightAlwaysOn ?? this.lightAlwaysOn,
        hasGlassHeater: hasGlassHeater ?? this.hasGlassHeater,
      );
}
