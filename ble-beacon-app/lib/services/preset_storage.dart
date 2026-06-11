import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/beacon.dart';

class PresetStorage {
  PresetStorage._();
  static final PresetStorage instance = PresetStorage._();

  static const _key = 'beacon_presets_v1';

  Future<List<BeaconPreset>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => BeaconPreset.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(List<BeaconPreset> presets) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(presets.map((p) => p.toJson()).toList());
    await prefs.setString(_key, raw);
  }

  Future<List<BeaconPreset>> add(BeaconPreset preset) async {
    final list = await load();
    list.removeWhere((p) => p.id == preset.id);
    list.add(preset);
    await save(list);
    return list;
  }

  Future<List<BeaconPreset>> remove(String id) async {
    final list = await load();
    list.removeWhere((p) => p.id == id);
    await save(list);
    return list;
  }
}
