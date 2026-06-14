import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

/// Логирование наблюдений сканера в CSV в отдельной папке `scanner_logs`.
/// Колонки: timestamp,name,id,rssi,distance_m
///   distance_m — оценка дистанции по лог-дистанционной модели RSSI.
///
/// Запись по каждой метке троттлится (не чаще раза в [_minIntervalMs]),
/// чтобы файл не разрастался при частых обновлениях рекламы.
class ScannerLogger {
  ScannerLogger._();
  static final ScannerLogger instance = ScannerLogger._();

  // Параметры лог-дистанционной модели (как в режиме «Траектория»).
  static const double txPower1m = -59.0;
  static const double pathLossN = 2.5;

  static const int _minIntervalMs = 1000;

  IOSink? _sink;
  File? _file;
  Directory? _dir;
  final Map<String, int> _lastWriteMs = {};

  Future<void> _open() async {
    if (_sink != null) return;
    final base = await getApplicationDocumentsDirectory();
    _dir = Directory('${base.path}/scanner_logs');
    if (!await _dir!.exists()) {
      await _dir!.create(recursive: true);
    }
    _file = File('${_dir!.path}/scanner_log.csv');
    final isNew = !await _file!.exists();
    _sink = _file!.openWrite(mode: FileMode.writeOnlyAppend);
    if (isNew) _sink!.writeln('timestamp,name,id,rssi,distance_m');
  }

  /// Оценка дистанции (м) по RSSI: d = 10^((tx - rssi)/(10·n)).
  static double distanceFromRssi(int rssi) =>
      pow(10, (txPower1m - rssi) / (10 * pathLossN)).toDouble();

  /// Записать наблюдение (троттлинг по [id]). [id] — стабильный ключ метки.
  Future<void> record({
    required String id,
    required String name,
    required int rssi,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final last = _lastWriteMs[id];
    if (last != null && nowMs - last < _minIntervalMs) return;
    _lastWriteMs[id] = nowMs;

    await _open();
    final ts = DateTime.now().toIso8601String();
    final dist = distanceFromRssi(rssi).toStringAsFixed(2);
    final safeName = name.replaceAll('"', "'");
    _sink!.writeln('$ts,"$safeName",$id,$rssi,$dist');
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
    _lastWriteMs.clear();
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
