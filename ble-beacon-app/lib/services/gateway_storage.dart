import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/gateway.dart';

class GatewayStorage {
  GatewayStorage._();
  static final GatewayStorage instance = GatewayStorage._();

  static const _key = 'gateway_config_v1';

  Future<GatewayConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return GatewayConfig.defaults;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return GatewayConfig.fromJson(map);
    } catch (_) {
      return GatewayConfig.defaults;
    }
  }

  Future<void> save(GatewayConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(config.toJson()));
  }
}
