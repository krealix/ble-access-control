import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Пишет события и RSSI-сэмплы шлюза в CSV-файл (для аудита и главы 3 ВКР).
/// Колонки (разделитель «;»): timestamp;event;vehicle;rssi;zone
///   timestamp — локальное время чч:мм:сс.мс; event = rssi | OPEN | OPEN_CALL
class GatewayLogger {
  GatewayLogger._();
  static final GatewayLogger instance = GatewayLogger._();

  IOSink? _sink;
  File? _file;

  Future<void> _open() async {
    if (_sink != null) return;
    final dir = await getApplicationDocumentsDirectory();
    _file = File('${dir.path}/gateway_log.csv');
    final isNew = !await _file!.exists();
    _sink = _file!.openWrite(mode: FileMode.writeOnlyAppend);
    if (isNew) _sink!.writeln('timestamp;event;vehicle;rssi;zone');
  }

  /// Локальная отметка времени «чч:мм:сс.мс».
  String get _ts {
    final n = DateTime.now();
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${p2(n.hour)}:${p2(n.minute)}:${p2(n.second)}'
        '.${n.millisecond.toString().padLeft(3, '0')}';
  }

  /// Экранирует значение для CSV с разделителем «;».
  static String _q(String v) => '"${v.replaceAll('"', "'").replaceAll(';', ',')}"';

  /// RSSI-сэмпл матча (буферизуется, без flush — их много).
  Future<void> rssi(String vehicle, int rssi, String zone) async {
    await _open();
    _sink!.writeln('$_ts;rssi;${_q(vehicle)};$rssi;$zone');
  }

  /// Событие открытия (важное — сразу сбрасываем на диск).
  Future<void> event(String event, String vehicle, [int? rssi]) async {
    await _open();
    _sink!.writeln('$_ts;$event;${_q(vehicle)};${rssi ?? ''};');
    await _sink!.flush();
  }

  /// Путь к файлу (с предварительным flush) — для экспорта/шаринга.
  Future<String> fileForExport() async {
    await _open();
    await _sink!.flush();
    return _file!.path;
  }

  Future<int> sizeBytes() async {
    await _open();
    await _sink!.flush();
    return _file!.existsSync() ? await _file!.length() : 0;
  }

  Future<void> clear() async {
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
    if (_file != null && await _file!.exists()) {
      await _file!.delete();
    }
    await _open();
  }

  Future<void> flushClose() async {
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
  }
}
