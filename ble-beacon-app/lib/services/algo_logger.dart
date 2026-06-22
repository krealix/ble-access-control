import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Отдельный лог трассировки алгоритма принятия решения о доступе.
///
/// Пишет в `algo_log.csv` по одной строке на каждое обработанное измерение
/// КАЖДОЙ метки в эфире (не только авторизованной) — для офлайн-анализа работы
/// алгоритма. Запись включается/выключается тумблером на экране шлюза; пока
/// логирование выключено, метод [record] ничего не делает.
///
/// Колонки (разделитель «;»):
///   timestamp;id;name;rssi;zone;A;B;auth;decision
///     timestamp — локальное время чч:мм:сс.мс;
///     zone — далеко|между|близко; A,B — счётчики пребывания в зонах;
///     auth — 1, если метка авторизована; decision — OPEN при открытии.
class AlgoLogger {
  AlgoLogger._();
  static final AlgoLogger instance = AlgoLogger._();

  /// Включено ли логирование (управляется тумблером в UI).
  bool enabled = false;

  IOSink? _sink;
  File? _file;

  Future<void> _open() async {
    if (_sink != null) return;
    final dir = await getApplicationDocumentsDirectory();
    _file = File('${dir.path}/algo_log.csv');
    final isNew = !await _file!.exists();
    _sink = _file!.openWrite(mode: FileMode.writeOnlyAppend);
    if (isNew) _sink!.writeln('timestamp;id;name;rssi;zone;A;B;auth;decision');
  }

  String get _ts {
    final n = DateTime.now();
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${p2(n.hour)}:${p2(n.minute)}:${p2(n.second)}'
        '.${n.millisecond.toString().padLeft(3, '0')}';
  }

  static String _q(String v) =>
      '"${v.replaceAll('"', "'").replaceAll(';', ',')}"';

  /// Записать шаг алгоритма. Если [enabled] == false — no-op.
  Future<void> record({
    required String id,
    required String name,
    required int rssi,
    required String zone,
    required int a,
    int? b,
    required bool auth,
    required bool open,
  }) async {
    if (!enabled) return;
    await _open();
    _sink!.writeln(
        '$_ts;$id;${_q(name)};$rssi;$zone;$a;${b ?? ''};${auth ? 1 : 0};'
        '${open ? 'OPEN' : ''}');
    if (open) await _sink!.flush(); // важное событие — на диск сразу
  }

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
