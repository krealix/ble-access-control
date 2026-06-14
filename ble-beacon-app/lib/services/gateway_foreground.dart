import 'package:flutter/services.dart';

/// Управление нативным foreground-сервисом шлюза (постоянное уведомление),
/// который не даёт системе усыпить BLE-сканирование в фоне / с погашенным
/// экраном. Сам сервис работу не ведёт — её ведёт Dart-монитор; сервис лишь
/// удерживает процесс живым.
class GatewayForeground {
  GatewayForeground._();
  static const _channel = MethodChannel('com.stown.ble_beacon_app/bt_info');

  static Future<void> start() async {
    try {
      await _channel.invokeMethod('startGatewayService');
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stopGatewayService');
    } catch (_) {}
  }
}
