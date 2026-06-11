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
}
