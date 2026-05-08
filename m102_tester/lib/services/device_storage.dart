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
  static const _defaultPin = '1234';
  static const _defaultGridColumns = 3;
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
}
