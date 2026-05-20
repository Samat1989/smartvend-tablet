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
  static const _defaultPin = '1234';
  static const _defaultGridColumns = 3;
  static const _defaultDispenseSensorMode = 1; // sensor required by default
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
}
