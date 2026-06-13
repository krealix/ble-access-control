import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;

import '../models/beacon.dart';
import '../models/gateway.dart';
import '../models/stown_packet.dart';
import 'beacon_parser.dart';
import 'hm10_sender.dart';
import 'incoming_call.dart';

/// Сервис мониторинга у шлагбаума: сканирует BLE, проверяет авторизацию,
/// отправляет сигнал в выбранном транспорте (HTTP / TCP / MQTT).
///
/// OR-логика матчинга: для каждой увиденной рекламы проверяем все ТС из
/// whitelist'а. Если у ТС хоть одно непустое поле (UUID/MAC/Major/Minor)
/// совпало с advertisement'ом — считаем это «своим».
class GatewayMonitor {
  GatewayMonitor({required this.config});

  GatewayConfig config;

  final StreamController<GatewayEvent> _events =
      StreamController<GatewayEvent>.broadcast();
  Stream<GatewayEvent> get events => _events.stream;

  bool _running = false;
  bool get isRunning => _running;

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<String>? _callSub;

  /// Окно последних попаданий per-vehicle (для anti-flicker через samples).
  final Map<String, List<DateTime>> _hits = {};

  /// Когда последний раз триггерили каждую машину (для cooldown).
  final Map<String, DateTime> _lastTrigger = {};

  Future<void> start() async {
    if (_running) return;
    _running = true;
    _emit(EventLevel.info, 'Мониторинг запущен');

    try {
      if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
        try {
          await FlutterBluePlus.turnOn();
        } catch (_) {
          _emit(EventLevel.error, 'Не удалось включить Bluetooth');
          _running = false;
          return;
        }
      }

      _scanSub = FlutterBluePlus.scanResults.listen(_onResults);
      await _beginScan();

      // Доступ по звонку (Вариант А): слушаем входящие вызовы, только если
      // в белом списке есть запись-телефон (ключ PHONE:...).
      final hasPhone = config.whitelist
          .any((v) => (v.matchKey ?? '').toUpperCase().startsWith('PHONE:'));
      if (hasPhone) {
        await IncomingCall.requestPermissions();
        _callSub = IncomingCall.instance.numbers.listen(_onIncomingCall);
        _emit(EventLevel.info, 'Доступ по звонку включён');
      }
    } catch (e) {
      _emit(EventLevel.error, 'Ошибка запуска: $e');
      _running = false;
    }
  }

  Future<void> _beginScan() => FlutterBluePlus.startScan(
        continuousUpdates: true,
        removeIfGone: const Duration(seconds: 10),
      );

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    await _scanSub?.cancel();
    _scanSub = null;
    await _callSub?.cancel();
    _callSub = null;
    _hits.clear();
    _emit(EventLevel.info, 'Мониторинг остановлен');
  }

  void updateConfig(GatewayConfig newConfig) {
    config = newConfig;
    _hits.clear();
    _emit(EventLevel.info, 'Настройки обновлены');
  }

  void _onResults(List<ScanResult> results) {
    for (final r in results) {
      _processResult(r);
    }
  }

  void _processResult(ScanResult r) {
    final advMac = r.device.remoteId.str;

    String? advUuid;
    int? advMajor;
    int? advMinor;
    final apple = r.advertisementData.manufacturerData[0x004C];
    if (apple != null &&
        apple.length >= 23 &&
        apple[0] == 0x02 &&
        apple[1] == 0x15) {
      advUuid = HexUtils.bytesToHex(apple.sublist(2, 18));
      advMajor = (apple[18] << 8) | apple[19];
      advMinor = (apple[20] << 8) | apple[21];
    }

    // STOWN-идентификатор из 10-байтного пакета (любая обёртка, кроме iBeacon).
    final advStownId = stownIdFromAdv(r.advertisementData);

    // Ключ метки для сверки с базой из «Сканера»:
    // STOWN-метка → "STOWN:ИМЯ", иначе → MAC-адрес.
    final advName = r.advertisementData.advName;
    final advKey = advStownId != null ? 'STOWN:$advName' : advMac;

    final rssi = r.rssi;

    AuthorizedVehicle? vehicle;
    for (final v in config.whitelist) {
      if (!v.isValid) continue;
      if (v.matches(
        advUuid: advUuid,
        advMac: advMac,
        advMajor: advMajor,
        advMinor: advMinor,
        advStownId: advStownId,
        advKey: advKey,
      )) {
        vehicle = v;
        break;
      }
    }
    if (vehicle == null) return;

    if (rssi < config.rssiThreshold) return;

    final key = vehicle.name;
    final now = DateTime.now();

    final last = _lastTrigger[key];
    if (last != null &&
        now.difference(last).inSeconds < config.cooldownSeconds) {
      return;
    }

    final window = _hits.putIfAbsent(key, () => []);
    window.removeWhere((t) => now.difference(t).inSeconds > 5);
    window.add(now);

    if (window.length >= config.samplesRequired) {
      _trigger(vehicle, advUuid, advMac, advMajor, advMinor, advStownId, advKey, rssi);
      _lastTrigger[key] = now;
      window.clear();
    } else {
      _emit(
        EventLevel.info,
        'Кандидат: ${vehicle.name} '
        '(${window.length}/${config.samplesRequired}, RSSI=$rssi)',
      );
    }
  }

  Future<void> _trigger(
    AuthorizedVehicle vehicle,
    String? advUuid,
    String advMac,
    int? advMajor,
    int? advMinor,
    String? advStownId,
    String? advKey,
    int rssi,
  ) async {
    final matchedFields = vehicle.explainMatch(
      advUuid: advUuid,
      advMac: advMac,
      advMajor: advMajor,
      advMinor: advMinor,
      advStownId: advStownId,
      advKey: advKey,
    );
    _emit(
      EventLevel.success,
      'Открытие: ${vehicle.name} · $matchedFields · RSSI=$rssi',
    );

    final info = <String, dynamic>{
      'vehicle': vehicle.name,
      'uuid': advUuid,
      'mac': advMac,
      'major': advMajor,
      'minor': advMinor,
      'stownId': advStownId,
      'rssi': rssi,
      'timestamp': DateTime.now().toIso8601String(),
    };

    await _openFor(advStownId: advStownId, info: info);
  }

  /// Открытие выбранным транспортом: HTTP шлёт JSON [info]; TCP/HM-10 — две
  /// STOWN-команды (0x01, пауза 500 мс, 0x87) с id метки (или нулями) и замком.
  Future<void> _openFor({
    String? advStownId,
    required Map<String, dynamic> info,
  }) async {
    final idBytes = _idBytes(advStownId);
    final lock = _lockNumber();
    final pkt01 =
        StownPacket.build(command: 0x01, identifier: idBytes, lockNumber: lock);
    final pkt87 =
        StownPacket.build(command: 0x87, identifier: idBytes, lockNumber: lock);

    switch (config.transport) {
      case GatewayTransport.http:
        await _sendHttp(info);
        break;
      case GatewayTransport.tcp:
        await _sendStownTcp(pkt01, pkt87);
        break;
      case GatewayTransport.hm10:
        await _sendStownHm10(pkt01, pkt87);
        break;
    }
  }

  /// Входящий звонок (Вариант А): сверяем номер с белым списком по ключу
  /// PHONE:<последние 10 цифр>. RSSI/окно проб не применяются — это явное
  /// действие; только cooldown.
  void _onIncomingCall(String last10) {
    final advKey = 'PHONE:$last10';
    AuthorizedVehicle? vehicle;
    for (final v in config.whitelist) {
      if (v.isValid && v.matches(advKey: advKey)) {
        vehicle = v;
        break;
      }
    }
    if (vehicle == null) {
      _emit(EventLevel.info, 'Звонок не из базы: …$last10');
      return;
    }

    final now = DateTime.now();
    final last = _lastTrigger[vehicle.name];
    if (last != null &&
        now.difference(last).inSeconds < config.cooldownSeconds) {
      return;
    }
    _lastTrigger[vehicle.name] = now;

    _emit(EventLevel.success, 'Открытие (звонок): ${vehicle.name} · …$last10');
    _openFor(info: <String, dynamic>{
      'vehicle': vehicle.name,
      'source': 'call',
      'phone': last10,
      'timestamp': now.toIso8601String(),
    });
  }

  /// 7 байт идентификатора для команды: из hex STOWN-ID метки, иначе нули.
  Uint8List _idBytes(String? stownIdHex) {
    final out = Uint8List(7);
    if (stownIdHex == null) return out;
    final clean = stownIdHex.replaceAll(RegExp('[^0-9A-Fa-f]'), '');
    for (var i = 0; i < 7 && i * 2 + 1 < clean.length; i++) {
      out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  /// Номер замка из настроек (hex → int, 0..0xFFFF).
  int _lockNumber() {
    final s = config.lockHex.trim().replaceAll('0x', '');
    return (int.tryParse(s, radix: 16) ?? 0) & 0xFFFF;
  }

  // ------------------------------------------------------------------ //
  // HTTP
  // ------------------------------------------------------------------ //

  Future<void> _sendHttp(Map<String, dynamic> info) async {
    try {
      final response = await http
          .post(
            Uri.parse(config.webhookUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(info),
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        _emit(EventLevel.success, 'HTTP: ${response.statusCode} OK');
      } else {
        _emit(
          EventLevel.error,
          'HTTP: ${response.statusCode} ${response.reasonPhrase ?? ""}',
        );
      }
    } on TimeoutException {
      _emit(EventLevel.error, 'HTTP: таймаут (5 сек)');
    } catch (e) {
      _emit(EventLevel.error, 'HTTP: $e');
    }
  }

  // ------------------------------------------------------------------ //
  // TCP — две STOWN-команды: 0x01, пауза 500 мс, 0x87.
  // ------------------------------------------------------------------ //

  Future<void> _sendStownTcp(Uint8List pkt01, Uint8List pkt87) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        config.tcpHost,
        config.tcpPort,
        timeout: const Duration(seconds: 5),
      );
      socket.add(pkt01);
      await socket.flush();
      _emit(EventLevel.success,
          'TCP: 0x01 → ${config.tcpHost}:${config.tcpPort}');
      await Future.delayed(const Duration(milliseconds: 500));
      socket.add(pkt87);
      await socket.flush();
      _emit(EventLevel.success,
          'TCP: 0x87 → ${config.tcpHost}:${config.tcpPort}');
    } on TimeoutException {
      _emit(EventLevel.error,
          'TCP: таймаут подключения к ${config.tcpHost}:${config.tcpPort}');
    } on SocketException catch (e) {
      _emit(EventLevel.error, 'TCP: ${e.message}');
    } catch (e) {
      _emit(EventLevel.error, 'TCP: $e');
    } finally {
      try {
        await socket?.close();
      } catch (_) {}
    }
  }

  // ------------------------------------------------------------------ //
  // HM-10 — подключение по GATT и запись 0x01, пауза 500 мс, 0x87.
  // ------------------------------------------------------------------ //

  Future<void> _sendStownHm10(Uint8List pkt01, Uint8List pkt87) async {
    final id = config.hm10Device.trim();
    if (id.isEmpty) {
      _emit(EventLevel.error, 'HM-10: не задан адрес устройства в настройках');
      return;
    }
    // Подключаться во время скана нельзя — останавливаем, потом возобновим.
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    try {
      final device = BluetoothDevice.fromId(id);
      await Hm10Sender.instance.sendPackets(
        device,
        [pkt01, pkt87],
        gap: const Duration(milliseconds: 500),
        onLog: (m) => _emit(EventLevel.info, 'HM-10: $m'),
      );
      _emit(EventLevel.success, 'HM-10: 0x01 и 0x87 отправлены → $id');
    } catch (e) {
      _emit(EventLevel.error, 'HM-10: $e');
    } finally {
      if (_running) {
        try {
          await _beginScan();
        } catch (_) {}
      }
    }
  }

  void _emit(EventLevel level, String message) {
    _events.add(GatewayEvent(
      timestamp: DateTime.now(),
      level: level,
      message: message,
    ));
  }

  void dispose() {
    stop();
    _events.close();
  }
}
