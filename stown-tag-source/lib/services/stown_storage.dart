import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/stown_packet.dart';

class StownStorage {
  StownStorage._();
  static final StownStorage instance = StownStorage._();

  static const _key = 'stown_config_v1';

  Future<StownConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) {
      final def = StownConfig.defaults;
      await save(def);
      return def;
    }
    try {
      final cfg = StownConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      // Гарантируем что device id есть
      if (cfg.deviceId.isEmpty) {
        return cfg.copyWith(deviceId: StownPacket.generateDeviceId());
      }
      return cfg;
    } catch (_) {
      return StownConfig.defaults;
    }
  }

  Future<void> save(StownConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(config.toJson()));
  }
}
