import 'package:flutter/services.dart';

/// Нормализация телефонного номера для сверки: оставляем только цифры и берём
/// последние 10 (чтобы +7… / 8… / 007… совпадали между собой).
String normalizePhone(String raw) {
  final digits = raw.replaceAll(RegExp(r'\D'), '');
  return digits.length > 10 ? digits.substring(digits.length - 10) : digits;
}

/// Поток входящих звонков (Вариант А): шлюз-телефон сам ловит RINGING и отдаёт
/// номер звонящего с нативной стороны через EventChannel.
class IncomingCall {
  IncomingCall._();
  static final IncomingCall instance = IncomingCall._();

  static const _events =
      EventChannel('com.stown.ble_beacon_app/incoming_call');
  static const _methods = MethodChannel('com.stown.ble_beacon_app/bt_info');

  /// Поток нормализованных номеров (последние 10 цифр) входящих вызовов.
  Stream<String> get numbers => _events
      .receiveBroadcastStream()
      .map((e) => normalizePhone('$e'))
      .where((n) => n.isNotEmpty);

  /// Запрос разрешений READ_PHONE_STATE + READ_CALL_LOG (нативно).
  static Future<void> requestPermissions() async {
    try {
      await _methods.invokeMethod('requestCallPermissions');
    } catch (_) {}
  }
}
