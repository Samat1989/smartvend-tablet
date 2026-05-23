import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-level persistent settings: machid, SmartVend secret (appkey),
/// service-mode PIN, language. Listeners are notified when pairing state
/// changes so UI can react.
class DeviceStorage extends ChangeNotifier {
  static const _kMachId = 'machid';
  static const _kSecret = 'secret';
  static const _kServicePin = 'service_pin';
  static const _kLanguage = 'language';
  static const _kGridColumns = 'grid_columns';
  static const _kDispenseSensorMode = 'dispense_sensor_mode';
  static const _kClimateMode = 'climate_mode';
  static const _kClimateSetpoint = 'climate_setpoint';
  static const _kClimateLight = 'climate_light_always_on';
  static const _kUseM102Password = 'use_m102_password';
  static const _kMachineLayout = 'machine_layout_v1';
  static const _defaultPin = '1234';
  static const _defaultGridColumns = 3;
  static const _defaultDispenseSensorMode = 1; // sensor required by default
  static const _defaultClimateSetpoint = 6.0;
  static const _defaultClimateLightOn = true;
  // — most installs have the IR curtain wired, so refund-on-no-drop is
  // the safer default for production. Operator can turn it off from the
  // inventory screen for machines without a sensor.
  static const minGridColumns = 2;
  static const maxGridColumns = 5;

  late SharedPreferences _prefs;
  bool _ready = false;

  bool get isReady => _ready;
  String? get machid => _prefs.getString(_kMachId);
  String? get secret => _prefs.getString(_kSecret);
  String get servicePin => _prefs.getString(_kServicePin) ?? _defaultPin;
  String get language => _prefs.getString(_kLanguage) ?? 'ru';

  /// How many product tiles per row in the customer catalog. Defaults to
  /// 3 — visually balanced on most tablets — but the operator can override
  /// 2..5 from the service menu for very narrow or very wide screens.
  int get gridColumns =>
      _prefs.getInt(_kGridColumns) ?? _defaultGridColumns;

  /// Drop-sensor (light-curtain) mode used for every real dispense.
  /// 0 = off (motor result only), 1 = sensor required (refund if no drop).
  /// Mode 2 (priority) is intentionally NOT exposed here — it's only
  /// available as a one-off override on the test-motor screen, where the
  /// operator may want to exercise the sensor without changing the
  /// machine's normal behaviour.
  int get dispenseSensorMode =>
      _prefs.getInt(_kDispenseSensorMode) ?? _defaultDispenseSensorMode;

  // ─── Climate settings ───────────────────────────────────────────
  // Stored as raw primitives so [DeviceStorage] doesn't have to
  // depend on the climate model. [ClimateController] is responsible
  // for translating to/from [ClimateConfig].

  /// Name of the climate mode enum (`off`/`cooling`/`heating`) or
  /// null if the operator has never picked one — caller substitutes
  /// the model-side default.
  String? get climateModeName => _prefs.getString(_kClimateMode);

  /// Setpoint in °C. Default 6 °C — matches the factory cooler default.
  double get climateSetpoint =>
      _prefs.getDouble(_kClimateSetpoint) ?? _defaultClimateSetpoint;

  /// Whether the LED strip stays on regardless of climate state.
  bool get climateLightAlwaysOn =>
      _prefs.getBool(_kClimateLight) ?? _defaultClimateLightOn;

  /// Whether [BoardClient] should mix the 11-byte M102 "password" into
  /// the outgoing CRC. `null` means "never probed yet" — BoardClient
  /// will auto-detect on the first successful connect and persist the
  /// winning value. Once set, BoardClient uses it as the starting
  /// guess on every subsequent connect (skipping the slow probe).
  bool? get useM102Password =>
      _prefs.containsKey(_kUseM102Password)
          ? _prefs.getBool(_kUseM102Password)
          : null;

  Future<void> setUseM102Password(bool v) async {
    await _prefs.setBool(_kUseM102Password, v);
    notifyListeners();
  }

  /// Raw JSON for the operator-built machine layout (shelves + slots).
  /// Null = never configured; caller falls back to a default grid.
  /// Parsing/serializing lives in [MachineLayout] so storage here
  /// stays a dumb string ↔ string codec.
  String? get machineLayoutJson => _prefs.getString(_kMachineLayout);

  Future<void> setMachineLayoutJson(String? json) async {
    if (json == null || json.isEmpty) {
      await _prefs.remove(_kMachineLayout);
    } else {
      await _prefs.setString(_kMachineLayout, json);
    }
    notifyListeners();
  }

  bool get isPaired {
    final m = machid;
    final s = secret;
    return m != null && m.isNotEmpty && s != null && s.isNotEmpty;
  }

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _ready = true;
    notifyListeners();
  }

  Future<void> savePairing({required String machid, required String secret}) async {
    await _prefs.setString(_kMachId, machid.trim());
    await _prefs.setString(_kSecret, secret.trim());
    notifyListeners();
  }

  Future<void> clearPairing() async {
    await _prefs.remove(_kMachId);
    await _prefs.remove(_kSecret);
    notifyListeners();
  }

  Future<void> setServicePin(String pin) async {
    await _prefs.setString(_kServicePin, pin);
    notifyListeners();
  }

  Future<void> setLanguage(String code) async {
    await _prefs.setString(_kLanguage, code);
    notifyListeners();
  }

  Future<void> setGridColumns(int n) async {
    final clamped = n.clamp(minGridColumns, maxGridColumns);
    await _prefs.setInt(_kGridColumns, clamped);
    notifyListeners();
  }

  Future<void> setDispenseSensorMode(int mode) async {
    // 0 = off, 1 = on. Mode 2 (priority) is rejected here so it can't
    // accidentally end up as the "all dispenses" default.
    final clamped = mode == 1 ? 1 : 0;
    await _prefs.setInt(_kDispenseSensorMode, clamped);
    notifyListeners();
  }

  Future<void> setClimateConfig({
    required String modeName,
    required double setpointC,
    required bool lightAlwaysOn,
  }) async {
    await _prefs.setString(_kClimateMode, modeName);
    await _prefs.setDouble(_kClimateSetpoint, setpointC);
    await _prefs.setBool(_kClimateLight, lightAlwaysOn);
    notifyListeners();
  }
}
