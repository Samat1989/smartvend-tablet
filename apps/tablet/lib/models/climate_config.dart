/// Output channel mapping on the M102 board (DO command 0x08).
/// Fixed by the factory firmware — do not change.
enum DoChannel {
  fan(0, 'climate_ch_fan'),
  compressor(1, 'climate_ch_compressor'),
  glassHeater(2, 'climate_ch_glass'),
  lightStrip(3, 'climate_ch_light'),
  heaterModule(4, 'climate_ch_heater');

  final int id;

  /// Key into `Strings`, not a finished label: a model has no business
  /// knowing which language the operator is reading.
  final String labelKey;
  const DoChannel(this.id, this.labelKey);
}

enum ClimateMode {
  off('climate_mode_off'),
  cooling('climate_mode_cooling'),
  heating('climate_mode_heating'),
  ;

  /// Key into `Strings` — see [DoChannel.labelKey].
  final String labelKey;
  const ClimateMode(this.labelKey);
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
