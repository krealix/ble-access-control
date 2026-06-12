import 'package:flutter/services.dart';

/// Получение MAC локального BT-адаптера через нативный method channel.
///
/// **Внимание:** на Android 6+ это поле обычно возвращает фейк
/// `02:00:00:00:00:00` ради приватности. Реальный MAC при advertising
/// тоже рандомизируется — каждая сессия вещания может быть с новым адресом.
/// Поле полезно только для отладки и при отключённой рандомизации
/// (developer options).
class BtInfo {
  BtInfo._();
  static const _channel =
      MethodChannel('com.stown.ble_beacon_app/bt_info');

  static Future<String?> getBluetoothMac() async {
    try {
      final result = await _channel.invokeMethod<String>('getBluetoothMac');
      return result;
    } catch (_) {
      return null;
    }
  }

  /// True если возвращается стандартная заглушка Android для приватности.
  static bool isMockMac(String? mac) {
    if (mac == null) return false;
    return mac.toUpperCase().replaceAll(':', '') == '020000000000';
  }

  /// Текущее имя BT-адаптера (GAP-имя устройства). На Android именно оно
  /// транслируется в рекламе при includeDeviceName=true.
  static Future<String?> getBluetoothName() async {
    try {
      return await _channel.invokeMethod<String>('getBluetoothName');
    } catch (_) {
      return null;
    }
  }

  /// Задаёт имя BT-адаптера (BluetoothAdapter.setName). Глобально меняет имя
  /// Bluetooth телефона. Применяется асинхронно — перед вещанием нужна
  /// небольшая пауза. Требует разрешение BLUETOOTH_CONNECT (Android 12+).
  /// Возвращает true, если операция принята.
  static Future<bool> setBluetoothName(String name) async {
    try {
      final ok = await _channel
          .invokeMethod<bool>('setBluetoothName', {'name': name});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}
