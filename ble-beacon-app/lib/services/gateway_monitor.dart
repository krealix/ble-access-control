import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../models/beacon.dart';
import '../models/gateway.dart';

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
      await FlutterBluePlus.startScan(
        continuousUpdates: true,
        removeIfGone: const Duration(seconds: 10),
      );
    } catch (e) {
      _emit(EventLevel.error, 'Ошибка запуска: $e');
      _running = false;
    }
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    await _scanSub?.cancel();
    _scanSub = null;
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

    final rssi = r.rssi;

    AuthorizedVehicle? vehicle;
    for (final v in config.whitelist) {
      if (!v.isValid) continue;
      if (v.matches(
        advUuid: advUuid,
        advMac: advMac,
        advMajor: advMajor,
        advMinor: advMinor,
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
      _trigger(vehicle, advUuid, advMac, advMajor, advMinor, rssi);
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
    int rssi,
  ) async {
    final matchedFields = vehicle.explainMatch(
      advUuid: advUuid,
      advMac: advMac,
      advMajor: advMajor,
      advMinor: advMinor,
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
      'rssi': rssi,
      'timestamp': DateTime.now().toIso8601String(),
    };

    switch (config.transport) {
      case GatewayTransport.http:
        await _sendHttp(info);
        break;
      case GatewayTransport.tcp:
        await _sendTcp(info);
        break;
      case GatewayTransport.mqtt:
        await _sendMqtt(info);
        break;
    }
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
  // TCP
  // ------------------------------------------------------------------ //

  Future<void> _sendTcp(Map<String, dynamic> info) async {
    final Uint8List payload;
    try {
      payload = _buildTcpPayload(info);
    } catch (e) {
      _emit(EventLevel.error, 'TCP payload: $e');
      return;
    }

    Socket? socket;
    try {
      socket = await Socket.connect(
        config.tcpHost,
        config.tcpPort,
        timeout: const Duration(seconds: 5),
      );
      socket.add(payload);
      await socket.flush();
      _emit(
        EventLevel.success,
        'TCP: ${payload.length} байт → ${config.tcpHost}:${config.tcpPort}',
      );
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

  Uint8List _buildTcpPayload(Map<String, dynamic> info) {
    switch (config.tcpPayloadFormat) {
      case TcpPayloadFormat.json:
        return Uint8List.fromList(utf8.encode('${jsonEncode(info)}\n'));

      case TcpPayloadFormat.text:
        var template = config.tcpPayloadTemplate;
        // Подставляем все ключи из info как {key}
        info.forEach((k, v) {
          template = template.replaceAll('{$k}', v == null ? '' : v.toString());
        });
        // Разворачиваем экранированные \n / \r
        template = template.replaceAll(r'\n', '\n').replaceAll(r'\r', '\r');
        return Uint8List.fromList(utf8.encode(template));

      case TcpPayloadFormat.hex:
        final clean = config.tcpPayloadTemplate
            .replaceAll(' ', '')
            .replaceAll(':', '')
            .replaceAll('\n', '')
            .replaceAll('\r', '');
        if (clean.length % 2 != 0) {
          throw FormatException('hex длина должна быть чётной');
        }
        final bytes = <int>[];
        for (var i = 0; i + 1 < clean.length; i += 2) {
          bytes.add(int.parse(clean.substring(i, i + 2), radix: 16));
        }
        return Uint8List.fromList(bytes);
    }
  }

  // ------------------------------------------------------------------ //
  // MQTT
  // ------------------------------------------------------------------ //

  Future<void> _sendMqtt(Map<String, dynamic> info) async {
    final clientId =
        'ble-gate-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    final client = MqttServerClient.withPort(
      config.mqttHost,
      clientId,
      config.mqttPort,
    );
    client.keepAlivePeriod = 10;
    client.logging(on: false);
    client.setProtocolV311();
    client.autoReconnect = false;

    final connMess = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .startClean()
        .withWillQos(MqttQos.atMostOnce);
    if (config.mqttUsername.isNotEmpty) {
      connMess.authenticateAs(config.mqttUsername, config.mqttPassword);
    }
    client.connectionMessage = connMess;

    try {
      await client
          .connect(
            config.mqttUsername.isEmpty ? null : config.mqttUsername,
            config.mqttUsername.isEmpty ? null : config.mqttPassword,
          )
          .timeout(const Duration(seconds: 5));

      if (client.connectionStatus?.state != MqttConnectionState.connected) {
        _emit(EventLevel.error,
            'MQTT: не подключиться к ${config.mqttHost}:${config.mqttPort}');
        client.disconnect();
        return;
      }

      final builder = MqttClientPayloadBuilder()..addString(jsonEncode(info));
      client.publishMessage(
        config.mqttTopic,
        MqttQos.atMostOnce,
        builder.payload!,
      );
      _emit(
        EventLevel.success,
        'MQTT: → ${config.mqttHost}:${config.mqttPort} / ${config.mqttTopic}',
      );
    } on TimeoutException {
      _emit(EventLevel.error, 'MQTT: таймаут подключения');
    } catch (e) {
      _emit(EventLevel.error, 'MQTT: $e');
    } finally {
      try {
        client.disconnect();
      } catch (_) {}
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
