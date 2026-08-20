import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'kiosk_bridge.dart';

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
  // Control-board protocol: unset = M102/M109E (20-byte Modbus-CRC frames,
  // 9600). 'lyt_v27' = BarysVend/LiYuTai V27.2 (AA..DD XOR frames, 115200) —
  // see docs/ИНТЕГРАЦИЯ_платы_LiYuTai_FINAL.md.
  static const _kBoardProtocol = 'board_protocol';
  // BarysVend only: swap ряд/колонка in outgoing dispense frames for
  // cross-wired cabinets (see BoardClient.lytSwapRowCol).
  static const _kLytSwapRowCol = 'lyt_swap_row_col';

  // Сколько секунд держать замок открытым в режиме микромаркета.
  // Живёт на планшете, а не в прошивке: у релейной платы нет сетевого OTA,
  // перепрошить её можно только кабелем — значит настройка обязана быть там,
  // где её меняют без визита к железу. Уходит в команду OPEN <сек>.
  static const _kLockHoldSeconds = 'lock_hold_seconds';
  static const _kShowSlotNumber = 'storefront_show_slot_number';
  static const _kShowShelfLabels = 'storefront_show_shelf_labels';
  static const _kSupportPhone = 'support_phone';
  static const _kSupportWhatsapp = 'support_whatsapp';
  static const _kSupportHours = 'support_hours';
  static const _kScreensaverDelaySec = 'screensaver_delay_sec';
  static const _kScreensaverSlideSec = 'screensaver_slide_sec';
  static const _kScreensaverWaitVideo = 'screensaver_wait_video_end';
  static const _kMachineLayout = 'machine_layout_v1';
  // When this tablet last saved a layout. Sent with the heartbeat so the
  // server can tell which of two tablets paired to the same machid edited
  // more recently — hashes alone would leave them re-pushing at each other.
  static const _kLayoutSavedAt = 'machine_layout_saved_at';
  static const _kDeviceId = 'device_id';
  // Operator-saved layout templates (JSON list of {name, layout}) —
  // see CustomLayoutTemplate in models/machine_layout.dart.
  static const _kCustomLayoutTemplates = 'custom_layout_templates_v1';
  static const _kPinFailCount = 'pin_fail_count';
  static const _kPinLockedUntil = 'pin_locked_until';
  static const _defaultGridColumns = 3;
  static const _defaultDispenseSensorMode = 1; // sensor required by default
  static const _defaultClimateSetpoint = 6.0;
  static const _defaultClimateLightOn = true;
  static const _defaultClimateHasGlassHeater = true;
  // Catalog columns. Capped at 3: past that the 44-dp add button and the
  // counter pill eat most of a card's width and the product photo stops
  // being readable from arm's length.
  static const minGridColumns = 2;
  static const maxGridColumns = 3;

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

  // Clamped on read as well as on write: a tablet that stored 4 or 5
  // before the cap would otherwise keep rendering them.
  int get gridColumns => (_prefs.getInt(_kGridColumns) ?? _defaultGridColumns)
      .clamp(minGridColumns, maxGridColumns);

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

  /// Persisted control-board protocol name, or null when never set
  /// (= M102/M109E default). [BoardClient] resolves it to its
  /// `BoardProtocol` enum on construction.
  String? get boardProtocolName => _prefs.getString(_kBoardProtocol);

  Future<void> setBoardProtocolName(String? name) async {
    if (name == null || name.isEmpty) {
      await _prefs.remove(_kBoardProtocol);
    } else {
      await _prefs.setString(_kBoardProtocol, name);
    }
    notifyListeners();
  }

  bool get lytSwapRowCol => _prefs.getBool(_kLytSwapRowCol) ?? false;

  Future<void> setLytSwapRowCol(bool v) async {
    await _prefs.setBool(_kLytSwapRowCol, v);
    notifyListeners();
  }

  /// Время удержания замка, секунды. 20 по умолчанию — столько же, сколько
  /// DEFAULT_OPEN_SECONDS в прошивке esp-pulse, чтобы поведение вариантов не
  /// разъезжалось. Границы те же, что у драйвера: 1..600.
  int get lockHoldSeconds =>
      (_prefs.getInt(_kLockHoldSeconds) ?? 20).clamp(1, 600);

  Future<void> setLockHoldSeconds(int v) async {
    await _prefs.setInt(_kLockHoldSeconds, v.clamp(1, 600));
    notifyListeners();
  }

  /// Show the slot number from the machine layout on storefront product
  /// cards. When on, a card with no photo shows the number in place of the
  /// picture instead of a generic emoji.
  ///
  /// The default depends on the machine, because the same digit means
  /// opposite things on the two of them. On a vending cabinet the doors are
  /// usually unnumbered, so it is noise — off. In a micromarket the number is
  /// written on the shelf and is the only thing tying the card to the physical
  /// goods — on.
  ///
  /// Only the DEFAULT is derived. The moment an operator touches the switch in
  /// «Витрина» their choice is stored and wins from then on, on either kind.
  bool get showSlotNumber =>
      _prefs.getBool(_kShowSlotNumber) ??
      (boardProtocolName == 'micromarket');

  Future<void> setShowSlotNumber(bool v) async {
    await _prefs.setBool(_kShowSlotNumber, v);
    notifyListeners();
  }

  /// Show the shelf header (numbered square + shelf label) above each row
  /// group on the catalog. On by default — that's how the storefront has
  /// always looked. Worth turning off on a cabinet whose shelves aren't
  /// labelled, where the header is just noise between rows of products.
  bool get showShelfLabels => _prefs.getBool(_kShowShelfLabels) ?? true;

  Future<void> setShowShelfLabels(bool v) async {
    await _prefs.setBool(_kShowShelfLabels, v);
    notifyListeners();
  }

  // ─── Customer support contact ───────────────────────────────────
  // Shown to the customer on the support screen, reached from the corner
  // badge on every customer-facing screen. Kept per-tablet rather than
  // pulled from the machine profile: it has to be readable when the
  // machine is offline, which is exactly when a customer is most likely
  // to be standing there with a failed dispense.

  String? _nonEmpty(String key) {
    final v = _prefs.getString(key);
    return (v == null || v.trim().isEmpty) ? null : v.trim();
  }

  Future<void> _setNonEmpty(String key, String? v) async {
    if (v == null || v.trim().isEmpty) {
      await _prefs.remove(key);
    } else {
      await _prefs.setString(key, v.trim());
    }
    notifyListeners();
  }

  /// Support phone as the operator typed it — shown verbatim, never
  /// reformatted. Kiosk tablets have no dialler, so this is something the
  /// customer reads and types into their own phone.
  String? get supportPhone => _nonEmpty(_kSupportPhone);

  Future<void> setSupportPhone(String? v) => _setNonEmpty(_kSupportPhone, v);

  /// WhatsApp number for the QR. Falls back to [supportPhone] when unset —
  /// on most machines it is the same line and making the operator type it
  /// twice would just be a way to get them out of sync.
  String? get supportWhatsapp => rawSupportWhatsapp ?? supportPhone;

  /// The stored WhatsApp override with no fallback applied. The service-mode
  /// editor prefills from this: showing the fallen-back phone would silently
  /// turn "same number" into a second copy to keep in sync by hand.
  String? get rawSupportWhatsapp => _nonEmpty(_kSupportWhatsapp);

  Future<void> setSupportWhatsapp(String? v) =>
      _setNonEmpty(_kSupportWhatsapp, v);

  /// Free-text working hours, e.g. «Пн–Пт, 9:00–18:00». Free text on
  /// purpose: every operator words this differently and a structured
  /// editor would fit none of them.
  String? get supportHours => _nonEmpty(_kSupportHours);

  Future<void> setSupportHours(String? v) => _setNonEmpty(_kSupportHours, v);

  /// Whether there is anything worth showing. The corner badge stays inert
  /// when false — a «Поддержка» button that opens an empty page is worse
  /// than no button at all.
  bool get hasSupportInfo => supportPhone != null || supportHours != null;

  // ─── Attract loop (screensaver) ─────────────────────────────────
  // Defaults reproduce the previous hard-coded behaviour: 5 minutes idle
  // before the loop opens, 3 seconds per slide.
  static const screensaverDelayChoicesSec = [60, 120, 300, 600, 900, 1800];
  static const screensaverSlideChoicesSec = [3, 5, 8, 10, 15, 20, 30];

  /// Idle time before the attract loop takes over the catalog.
  int get screensaverDelaySec =>
      _prefs.getInt(_kScreensaverDelaySec) ?? 300;

  Future<void> setScreensaverDelaySec(int v) async {
    await _prefs.setInt(_kScreensaverDelaySec, v);
    notifyListeners();
  }

  /// How long one slide stays on screen. For videos this is only used
  /// when [screensaverWaitVideoEnd] is off — otherwise the clip's own
  /// length decides.
  int get screensaverSlideSec => _prefs.getInt(_kScreensaverSlideSec) ?? 3;

  Future<void> setScreensaverSlideSec(int v) async {
    await _prefs.setInt(_kScreensaverSlideSec, v);
    notifyListeners();
  }

  /// Let a video play to its end before moving on. On by default: the
  /// old loop cut every clip off at the slide interval, which made
  /// anything longer than a few seconds pointless to upload.
  bool get screensaverWaitVideoEnd =>
      _prefs.getBool(_kScreensaverWaitVideo) ?? true;

  Future<void> setScreensaverWaitVideoEnd(bool v) async {
    await _prefs.setBool(_kScreensaverWaitVideo, v);
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

  String? get customLayoutTemplatesJson =>
      _prefs.getString(_kCustomLayoutTemplates);

  Future<void> setCustomLayoutTemplatesJson(String? json) async {
    if (json == null || json.isEmpty) {
      await _prefs.remove(_kCustomLayoutTemplates);
    } else {
      await _prefs.setString(_kCustomLayoutTemplates, json);
    }
    notifyListeners();
  }

  Future<void> setMachineLayoutJson(String? json) async {
    if (json == null || json.isEmpty) {
      await _prefs.remove(_kMachineLayout);
      await _prefs.remove(_kLayoutSavedAt);
    } else {
      await _prefs.setString(_kMachineLayout, json);
      await _prefs.setString(
          _kLayoutSavedAt, DateTime.now().toUtc().toIso8601String());
    }
    notifyListeners();
  }

  /// UTC ISO-8601 of the last local layout save, or null on a tablet that
  /// has never saved one (its layout came from a template default).
  String? get machineLayoutSavedAt => _prefs.getString(_kLayoutSavedAt);

  /// Identity this tablet claims a machine with. ANDROID_ID when the ROM
  /// gives one — it survives an app reinstall, so re-flashing the APK on the
  /// same tablet doesn't look like a different device and doesn't need the
  /// owner to unbind. Otherwise a UUID generated once and kept here, which
  /// only loses the claim if the app's data is wiped.
  ///
  /// Resolved once and cached: the claim must not change under us mid-session.
  String? _deviceId;

  Future<String> deviceId() async {
    if (_deviceId != null) return _deviceId!;
    final stored = _prefs.getString(_kDeviceId);
    if (stored != null && stored.isNotEmpty) {
      _deviceId = stored;
      return stored;
    }
    final android = await KioskBridge.androidId();
    final id = android ?? 'gen-${DateTime.now().microsecondsSinceEpoch}-'
        '${Random().nextInt(0x7fffffff).toRadixString(16)}';
    await _prefs.setString(_kDeviceId, id);
    _deviceId = id;
    return id;
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
