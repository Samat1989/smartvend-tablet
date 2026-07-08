import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-level persistent settings: machid, SmartVend secret (appkey),
/// service-mode PIN, language. Listeners are notified when pairing state
/// changes so UI can react.
///
/// Sensitive values — the SmartVend `secret` (payment signing appkey) and
/// the service `PIN` — live in Android Keystore-backed secure storage
/// (audit F3). Everything else stays in plain SharedPreferences. The
/// sensitive values are hydrated into memory in [init] so the rest of the
/// app keeps simple synchronous getters; writes go through to the Keystore.
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
  static const _kClimateHasGlassHeater = 'climate_has_glass_heater';
  static const _kUseM102Password = 'use_m102_password';
  // Board serial link: unset/empty = USB adapter (auto-detect CH340);
  // a "/dev/ttySX" value = native on-SoC UART (industrial tablets whose
  // serial port is wired straight to the SoC, no USB-serial chip).
  static const _kSerialPort = 'board_serial_port';
  static const _kMachineLayout = 'machine_layout_v1';
  static const _kPinFailCount = 'pin_fail_count';
  static const _kPinLockedUntil = 'pin_locked_until';
  static const _defaultGridColumns = 3;
  static const _defaultDispenseSensorMode = 1; // sensor required by default
  static const _defaultClimateSetpoint = 6.0;
  static const _defaultClimateLightOn = true;
  static const _defaultClimateHasGlassHeater = true;
  static const minGridColumns = 2;
  static const maxGridColumns = 5;

  /// Service-PIN policy.
  static const minPinLength = 4;
  static const maxPinAttempts = 10;
  static const pinLockoutMinutes = 15;
  /// PINs that are too obvious to allow (the old hardcoded default lived here).
  static const forbiddenPins = {'1234', '0000', '1111', '123456'};

  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  late SharedPreferences _prefs;
  bool _ready = false;

  // In-memory mirror of the Keystore-held sensitive values (hydrated in init).
  String? _secret;
  String? _servicePin;

  bool get isReady => _ready;
  String? get machid => _prefs.getString(_kMachId);
  String? get secret => _secret;
  String get language => _prefs.getString(_kLanguage) ?? 'ru';

  int get gridColumns =>
      _prefs.getInt(_kGridColumns) ?? _defaultGridColumns;

  int get dispenseSensorMode =>
      _prefs.getInt(_kDispenseSensorMode) ?? _defaultDispenseSensorMode;

  String? get climateModeName => _prefs.getString(_kClimateMode);

  double get climateSetpoint =>
      _prefs.getDouble(_kClimateSetpoint) ?? _defaultClimateSetpoint;

  bool get climateLightAlwaysOn =>
      _prefs.getBool(_kClimateLight) ?? _defaultClimateLightOn;

  bool get climateHasGlassHeater =>
      _prefs.getBool(_kClimateHasGlassHeater) ?? _defaultClimateHasGlassHeater;

  bool? get useM102Password =>
      _prefs.containsKey(_kUseM102Password)
          ? _prefs.getBool(_kUseM102Password)
          : null;

  Future<void> setUseM102Password(bool v) async {
    await _prefs.setBool(_kUseM102Password, v);
    notifyListeners();
  }

  /// Native UART node the board is wired to (e.g. `/dev/ttyS2`), or null
  /// to use a USB-serial adapter. Drives which transport [BoardClient]
  /// opens on boot.
  String? get serialPortPath {
    final v = _prefs.getString(_kSerialPort);
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> setSerialPortPath(String? path) async {
    if (path == null || path.isEmpty) {
      await _prefs.remove(_kSerialPort);
    } else {
      await _prefs.setString(_kSerialPort, path);
    }
    notifyListeners();
  }

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
    final s = _secret;
    return m != null && m.isNotEmpty && s != null && s.isNotEmpty;
  }

  // ─── Service PIN ────────────────────────────────────────────────

  /// True once a real PIN has been set. There is no implicit default any
  /// more (the old '1234' is gone) — when this is false the UI forces the
  /// operator to create one before service mode can be entered.
  bool get servicePinIsSet => _servicePin != null && _servicePin!.isNotEmpty;

  /// Constant-ish equality check. Does not mutate attempt state.
  bool verifyServicePin(String entered) =>
      servicePinIsSet && entered.trim() == _servicePin;

  /// Returns null if [pin] is acceptable, or a human-readable reason why not.
  static String? validatePin(String pin) {
    final p = pin.trim();
    if (p.length < minPinLength) return 'Минимум $minPinLength цифры';
    if (forbiddenPins.contains(p)) return 'Слишком простой PIN';
    return null;
  }

  int get pinFailCount => _prefs.getInt(_kPinFailCount) ?? 0;
  int get pinAttemptsRemaining =>
      (maxPinAttempts - pinFailCount).clamp(0, maxPinAttempts);

  /// When the PIN entry is locked out, the moment it unlocks — else null.
  DateTime? get pinLockedUntil {
    final ms = _prefs.getInt(_kPinLockedUntil);
    if (ms == null) return null;
    final until = DateTime.fromMillisecondsSinceEpoch(ms);
    return DateTime.now().isBefore(until) ? until : null;
  }

  bool get isPinLocked => pinLockedUntil != null;

  /// Record a failed PIN entry. Returns true if this failure tripped a
  /// lockout. The counter + lockout deadline are persisted so killing and
  /// relaunching the app can't reset them.
  Future<bool> registerPinFailure() async {
    final n = pinFailCount + 1;
    if (n >= maxPinAttempts) {
      await _prefs.setInt(_kPinFailCount, 0);
      await _prefs.setInt(
        _kPinLockedUntil,
        DateTime.now()
            .add(const Duration(minutes: pinLockoutMinutes))
            .millisecondsSinceEpoch,
      );
      notifyListeners();
      return true;
    }
    await _prefs.setInt(_kPinFailCount, n);
    notifyListeners();
    return false;
  }

  Future<void> resetPinAttempts() async {
    await _prefs.remove(_kPinFailCount);
    await _prefs.remove(_kPinLockedUntil);
    notifyListeners();
  }

  /// Set/replace the service PIN. Caller must [validatePin] first.
  Future<void> setServicePin(String pin) async {
    _servicePin = pin.trim();
    try {
      await _secure.write(key: _kServicePin, value: _servicePin);
    } catch (e) {
      debugPrint('[DeviceStorage] pin write failed: $e');
    }
    await resetPinAttempts();
    notifyListeners();
  }

  // ─── Lifecycle ──────────────────────────────────────────────────

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    try {
      _secret = await _secure.read(key: _kSecret);
      _servicePin = await _secure.read(key: _kServicePin);
    } catch (e) {
      debugPrint('[DeviceStorage] secure read failed: $e');
    }
    await _migrateSensitiveFromPrefs();
    _ready = true;
    notifyListeners();
  }

  /// One-time migration of secret/PIN out of the legacy plaintext
  /// SharedPreferences into the Keystore. Only copies when the secure slot
  /// is empty, and only removes the plaintext copy after a confirmed write.
  /// Machines that ran on the old implicit default PIN ('1234', never
  /// actually stored) arrive here with no PIN and will be forced to create
  /// one on first service-mode entry.
  Future<void> _migrateSensitiveFromPrefs() async {
    try {
      final legacySecret = _prefs.getString(_kSecret);
      if ((_secret == null || _secret!.isEmpty) &&
          legacySecret != null &&
          legacySecret.isNotEmpty) {
        await _secure.write(key: _kSecret, value: legacySecret);
        _secret = legacySecret;
        await _prefs.remove(_kSecret);
        debugPrint('[DeviceStorage] migrated secret to Keystore');
      }
      final legacyPin = _prefs.getString(_kServicePin);
      if ((_servicePin == null || _servicePin!.isEmpty) &&
          legacyPin != null &&
          legacyPin.isNotEmpty) {
        await _secure.write(key: _kServicePin, value: legacyPin);
        _servicePin = legacyPin;
        await _prefs.remove(_kServicePin);
        debugPrint('[DeviceStorage] migrated service PIN to Keystore');
      }
    } catch (e) {
      debugPrint('[DeviceStorage] migration failed: $e');
    }
  }

  Future<void> savePairing({required String machid, required String secret}) async {
    await _prefs.setString(_kMachId, machid.trim());
    _secret = secret.trim();
    try {
      await _secure.write(key: _kSecret, value: _secret);
    } catch (e) {
      debugPrint('[DeviceStorage] secret write failed: $e');
    }
    notifyListeners();
  }

  Future<void> clearPairing() async {
    await _prefs.remove(_kMachId);
    _secret = null;
    try {
      await _secure.delete(key: _kSecret);
    } catch (e) {
      debugPrint('[DeviceStorage] secret delete failed: $e');
    }
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
    final clamped = mode == 1 ? 1 : 0;
    await _prefs.setInt(_kDispenseSensorMode, clamped);
    notifyListeners();
  }

  Future<void> setClimateConfig({
    required String modeName,
    required double setpointC,
    required bool lightAlwaysOn,
    required bool hasGlassHeater,
  }) async {
    await _prefs.setString(_kClimateMode, modeName);
    await _prefs.setDouble(_kClimateSetpoint, setpointC);
    await _prefs.setBool(_kClimateLight, lightAlwaysOn);
    await _prefs.setBool(_kClimateHasGlassHeater, hasGlassHeater);
    notifyListeners();
  }
}
