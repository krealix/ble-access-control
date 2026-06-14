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
import 'gateway_logger.dart';
import 'hm10_sender.dart';
import 'incoming_call.dart';
import 'rolling_code.dart';
import 'trajectory.dart';

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
  Timer? _absenceTimer;

  /// Состояние «мёртвой зоны» per-vehicle (BLE-открытие).
  final Map<String, _TagState> _fsm = {};

  /// Анализатор траектории per-vehicle (режим decisionMode == 'trajectory').
  final Map<String, TrajectoryAnalyzer> _traj = {};

  /// Когда последний раз открывали по звонку (cooldown для звонков).
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
      _fsm.clear();
      _traj.clear();
      _absenceTimer = Timer.periodic(
          const Duration(seconds: 1), (_) => _checkAbsence());

      // Доступ по звонку (Вариант А): слушаем входящие вызовы, если включён
      // доступ по звонку и в белом списке есть запись-телефон (ключ PHONE:...).
      final hasPhone = config.whitelist
          .any((v) => (v.matchKey ?? '').toUpperCase().startsWith('PHONE:'));
      if (config.callAccessEnabled && hasPhone) {
        await IncomingCall.requestPermissions();
        if (config.callHangup) await IncomingCall.requestHangupPermission();
        _callSub = IncomingCall.instance.numbers.listen(_onIncomingCall);
        _emit(
            EventLevel.info,
            config.callHangup
                ? 'Доступ по звонку включён (со сбросом)'
                : 'Доступ по звонку включён');
      }

      // HM-10: заранее открываем постоянное подключение (если это транспорт),
      // чтобы открытие было мгновенным и надёжным.
      if (config.transport == GatewayTransport.hm10 &&
          config.hm10Device.trim().isNotEmpty) {
        unawaited(Hm10Sender.instance
            .ensureConnected(config.hm10Device,
                onLog: (m) => _emit(EventLevel.info, 'HM-10: $m'))
            .catchError((Object e) =>
                _emit(EventLevel.error, 'HM-10: предв. подключение — $e')));
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
    _absenceTimer?.cancel();
    _absenceTimer = null;
    _fsm.clear();
    _traj.clear();
    await Hm10Sender.instance.disconnectPersistent();
    _emit(EventLevel.info, 'Мониторинг остановлен');
  }

  void updateConfig(GatewayConfig newConfig) {
    config = newConfig;
    _fsm.clear();
    _traj.clear();
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
      final byStatic = v.matches(
        advUuid: advUuid,
        advMac: advMac,
        advMajor: advMajor,
        advMinor: advMinor,
        advStownId: advStownId,
        advKey: advKey,
      );
      // Динамическая метка: сверяем принятый id с rolling-кодом секрета.
      final byRolling = v.secret != null &&
          v.secret!.isNotEmpty &&
          advStownId != null &&
          RollingCode.matches(v.secret!, advStownId);
      if (byStatic || byRolling) {
        vehicle = v;
        break;
      }
    }
    if (vehicle == null) return;

    final key = vehicle.name;
    final now = DateTime.now();
    final st = _fsm.putIfAbsent(key, () => _TagState());
    st.lastSeen = now;

    // Режим «Траектория» (ядро ВКР): Калман → лог-дистанция → тренд (МНК) → КА.
    // Решение принимается по устойчивому приближению, а не по мгновенному порогу.
    if (config.decisionMode == 'trajectory') {
      final an = _traj.putIfAbsent(key, _newAnalyzer);
      final s = an.push(now.millisecondsSinceEpoch / 1000.0, rssi.toDouble());
      st.lastRssi = s.rssi.round();
      // Для карточки живого статуса: «рядом» = доступ выдан/приближается.
      st.state = (s.state == Access.granted || s.state == Access.approaching)
          ? _Zone.near
          : _Zone.far;
      if (s.justGranted) {
        _trigger(vehicle, advUuid, advMac, advMajor, advMinor, advStownId,
            advKey, s.rssi.round());
      }
      unawaited(GatewayLogger.instance.rssi(vehicle.name, rssi, s.state.name));
      return;
    }

    // «Мёртвая зона» (гистерезис): открываем при устойчивом «рядом» из
    // состояния «далеко/армед»; повторно — только после устойчивого «далеко»
    // (или пропажи из зоны, см. _checkAbsence). Это убирает постоянные открытия.
    // EMA-сглаживание: гасит редкие всплески RSSI перед порогами.
    st.ema = st.ema == null
        ? rssi.toDouble()
        : _emaAlpha * rssi + (1 - _emaAlpha) * st.ema!;
    final srssi = st.ema!.round();
    st.lastRssi = srssi;

    if (srssi >= config.rssiNear) {
      st.farSince = null;
      st.nearSince ??= now;
      if (st.state == _Zone.far &&
          now.difference(st.nearSince!).inMilliseconds >= config.tCloseMs) {
        st.state = _Zone.near;
        _trigger(vehicle, advUuid, advMac, advMajor, advMinor, advStownId,
            advKey, srssi);
      }
    } else if (srssi <= config.rssiFar) {
      st.nearSince = null;
      st.farSince ??= now;
      if (st.state == _Zone.near &&
          now.difference(st.farSince!).inMilliseconds >= config.tFarMs) {
        st.state = _Zone.far;
        _emit(EventLevel.info, 'Перевзвод: ${vehicle.name} (отошла)');
      }
    } else {
      // Между порогами — мёртвая зона: держим состояние, сбрасываем таймеры.
      st.nearSince = null;
      st.farSince = null;
    }

    // В лог пишем СЫРОЙ RSSI (для офлайн-анализа траектории) + текущую зону.
    unawaited(GatewayLogger.instance
        .rssi(vehicle.name, rssi, st.state == _Zone.near ? 'near' : 'far'));
  }

  /// Снимок живого состояния меток для UI (зона/RSSI/последний контакт).
  Map<String, TagLive> liveSnapshot() => {
        for (final e in _fsm.entries)
          e.key: TagLive(
            zone: e.value.state == _Zone.near ? 'near' : 'far',
            rssi: e.value.lastRssi,
            lastSeen: e.value.lastSeen,
          ),
      };

  /// Новый анализатор траектории с параметрами из конфигурации.
  TrajectoryAnalyzer _newAnalyzer() => TrajectoryAnalyzer(
        grantDistance: config.grantDistance,
        approachSamples: config.approachSamples,
        trendEps: config.trendEps,
        txPower: config.txPower1m,
        n: config.pathLossN,
      );

  /// Периодическая проверка: метка пропала из зоны на ≥ tFarMs → перевзвод.
  void _checkAbsence() {
    final now = DateTime.now();
    for (final e in _fsm.entries) {
      final st = e.value;
      if (st.state == _Zone.near &&
          now.difference(st.lastSeen).inMilliseconds >= config.tFarMs) {
        st.state = _Zone.far;
        st.nearSince = null;
        st.farSince = null;
        // Сброс анализатора траектории, чтобы новое приближение перевзвело КА.
        _traj.remove(e.key);
      }
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
    unawaited(GatewayLogger.instance.event('OPEN', vehicle.name, rssi));

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
  /// команды (cmd1, пауза 500 мс, cmd2). Идентификатор (байты 2-8) во 2-м пакете
  /// — это [idOverride] (напр. номер в BCD) или id метки; в 1-м пакете — нули,
  /// если включён firstZeroId. Командные байты настраиваются (cmd1Hex/cmd2Hex).
  Future<void> _openFor({
    String? advStownId,
    Uint8List? idOverride,
    required Map<String, dynamic> info,
  }) async {
    final realId = idOverride ?? _idBytes(advStownId);
    final lock = _lockNumber();
    final cmd1 = _cmdByte(config.cmd1Hex, 0x01);
    final cmd2 = _cmdByte(config.cmd2Hex, 0x87);
    final id1 = config.firstZeroId ? Uint8List(kIdLen) : realId;
    final pkt1 =
        StownPacket.build(command: cmd1, identifier: id1, lockNumber: lock);
    final pkt2 =
        StownPacket.build(command: cmd2, identifier: realId, lockNumber: lock);

    switch (config.transport) {
      case GatewayTransport.http:
        await _sendHttp(info);
        break;
      case GatewayTransport.tcp:
        await _sendStownTcp(pkt1, pkt2);
        break;
      case GatewayTransport.hm10:
        await _sendStownHm10(pkt1, pkt2);
        break;
    }
  }

  /// Командный байт из hex-настройки (0..255), иначе [fallback].
  int _cmdByte(String hex, int fallback) {
    final s = hex.trim().replaceAll('0x', '');
    return (int.tryParse(s, radix: 16) ?? fallback) & 0xFF;
  }

  /// Входящий звонок (Вариант А): сверяем номер с белым списком по ключу
  /// PHONE:<последние 10 цифр>. RSSI/окно проб не применяются — это явное
  /// действие; только cooldown.
  void _onIncomingCall(String last10) {
    // Шлюз-телефон выделенный: сбрасываем звонок сразу после чтения номера.
    if (config.callHangup) {
      unawaited(IncomingCall.endCall());
    }

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

    // Идентификатор пакета (байты 2-8) — номер звонящего в BCD (7 байт, 14 цифр).
    Uint8List? idBcd;
    try {
      idBcd = StownPacket.buildIdentifier(IdentifierMode.phone, last10);
    } catch (_) {
      idBcd = null;
    }

    _emit(EventLevel.success, 'Открытие (звонок): ${vehicle.name} · …$last10');
    unawaited(GatewayLogger.instance.event('OPEN_CALL', vehicle.name));
    _openFor(idOverride: idBcd, info: <String, dynamic>{
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

  Future<void> _sendStownTcp(Uint8List pkt1, Uint8List pkt2) async {
    final dst = '${config.tcpHost}:${config.tcpPort}';
    Socket? socket;
    try {
      socket = await Socket.connect(
        config.tcpHost,
        config.tcpPort,
        timeout: const Duration(seconds: 5),
      );
      socket.add(pkt1);
      await socket.flush();
      _emit(EventLevel.success, 'TCP: ${_hb(pkt1)} → $dst');
      await Future.delayed(const Duration(milliseconds: 500));
      socket.add(pkt2);
      await socket.flush();
      _emit(EventLevel.success, 'TCP: ${_hb(pkt2)} → $dst');
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
  // HM-10 — постоянное GATT-подключение, запись 0x01, пауза 500 мс, 0x87.
  // Постоянное подключение надёжнее, чем connect на каждое открытие, и
  // сосуществует со сканированием (не нужно его останавливать).
  // ------------------------------------------------------------------ //

  Future<void> _sendStownHm10(Uint8List pkt1, Uint8List pkt2) async {
    // Android getRemoteDevice требует MAC в ВЕРХНЕМ регистре с двоеточиями.
    final id = config.hm10Device.trim().toUpperCase();
    if (id.isEmpty) {
      _emit(EventLevel.error, 'HM-10: не задан адрес устройства в настройках');
      return;
    }
    if (!RegExp(r'^([0-9A-F]{2}:){5}[0-9A-F]{2}$').hasMatch(id)) {
      _emit(EventLevel.error,
          'HM-10: неверный MAC «$id» — нужен формат AA:BB:CC:DD:EE:FF');
      return;
    }
    try {
      void log(String m) => _emit(EventLevel.info, 'HM-10: $m');
      await Hm10Sender.instance.writePersistent(id, pkt1, onLog: log);
      await Future.delayed(const Duration(milliseconds: 500));
      await Hm10Sender.instance.writePersistent(id, pkt2, onLog: log);
      _emit(EventLevel.success,
          'HM-10: ${_hb(pkt1)} и ${_hb(pkt2)} отправлены → $id');
    } catch (e) {
      _emit(EventLevel.error, 'HM-10: $e');
    }
  }

  /// Краткая запись команды пакета для лога: «0x87».
  String _hb(Uint8List pkt) =>
      '0x${pkt.isEmpty ? '00' : pkt.first.toRadixString(16).padLeft(2, '0')}';

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

/// Коэффициент EMA-сглаживания RSSI (0..1; больше — отзывчивее, меньше — глаже).
const double _emaAlpha = 0.4;

/// Зона метки в гистерезисе.
enum _Zone { far, near }

/// Состояние «мёртвой зоны» для одной метки.
class _TagState {
  _Zone state = _Zone.far; // старт «армед» — первое приближение откроет
  DateTime? nearSince; // когда RSSI впервые стал ≥ P_close непрерывно
  DateTime? farSince; // когда RSSI ≤ P_dist непрерывно
  DateTime lastSeen = DateTime.now();
  double? ema; // сглаженный RSSI
  int lastRssi = -127; // последний сглаженный RSSI (для UI)
}

/// Снимок живого состояния метки для UI.
class TagLive {
  TagLive({required this.zone, required this.rssi, required this.lastSeen});
  final String zone; // 'near' | 'far'
  final int rssi;
  final DateTime lastSeen;
}
