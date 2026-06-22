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

  /// Запрашивает разрешения «телефона» ОДНИМ диалогом: READ_PHONE_STATE,
  /// READ_CALL_LOG и (если [withHangup]) ANSWER_PHONE_CALLS. Раздельные запросы
  /// нельзя — система показывает только один диалог за раз и второй отбрасывает.
  ///
  /// Возвращает true, если разрешение на сброс звонка реально выдано; при
  /// [withHangup] == false всегда true (сброс не запрашивался).
  static Future<bool> requestCallPermissions({bool withHangup = false}) async {
    try {
      final res = await _methods.invokeMethod(
          'requestCallPermissions', {'withHangup': withHangup});
      if (!withHangup) return true;
      return res is Map && res['hangupGranted'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Открыть системный экран настроек приложения — для ручной выдачи
  /// разрешения, если оно было отклонено «навсегда».
  static Future<void> openAppSettings() async {
    try {
      await _methods.invokeMethod('openAppSettings');
    } catch (_) {}
  }

  /// Сбросить текущий входящий звонок (TelecomManager.endCall, Android 9+).
  /// Возвращает статус-строку для диагностики: ok / no_permission /
  /// api_too_old / no_telecom / endcall_false / error.
  static Future<String> endCall() async {
    try {
      final r = await _methods.invokeMethod('endCall');
      return r?.toString() ?? 'unknown';
    } catch (e) {
      return 'error';
    }
  }
}
