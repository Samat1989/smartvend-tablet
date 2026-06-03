import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/provisioning_config.dart';

/// Single-config store backed by SharedPreferences. The form is small
/// enough that we save on every field change and reload on app start
/// — no manual "Save" button needed. Multi-profile support (office /
/// warehouse / customer-site Wi-Fi) is out of scope for now; operator
/// can keep one set of values that they tweak per visit.
class ConfigStorage {
  ConfigStorage(this._prefs);

  final SharedPreferences _prefs;

  static const _kConfig = 'provisioning_config_v1';

  static Future<ConfigStorage> open() async {
    final prefs = await SharedPreferences.getInstance();
    return ConfigStorage(prefs);
  }

  ProvisioningConfig load() {
    final raw = _prefs.getString(_kConfig);
    if (raw == null) return ProvisioningConfig();
    try {
      return ProvisioningConfig.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return ProvisioningConfig();
    }
  }

  Future<void> save(ProvisioningConfig cfg) async {
    await _prefs.setString(_kConfig, jsonEncode(cfg.toJson()));
  }
}
