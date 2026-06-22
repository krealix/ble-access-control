import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;

import '../models/beacon.dart';
import '../models/gateway.dart';
import '../models/stown_packet.dart';
import 'access_algorithm.dart';
import 'algo_logger.dart';
import 'beacon_parser.dart';
import 'gateway_logger.dart';
import 'hm10_sender.dart';
import 'incoming_call.dart';
import 'rolling_code.dart';

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

  /// Алгоритм доступа по гистерезису зон сигнала. Состояние счётчиков ведётся
  /// внутри по ключу метки (для авторизованных — по имени ТС, иначе по id/MAC).
  late ZoneAccessAlgorithm _algo = _newAlgo();

  /// Когда последний раз видели метку (по ключу алгоритма) — для удаления
  /// записей пропавших меток (absenceSeconds).
  final Map<String, DateTime> _lastSeen = {};

  /// Когда последний раз прогоняли алгоритм по метке — троттлинг опроса до
  /// config.pollHz раз в секунду (период [_pollMs]).
  final Map<String, DateTime> _lastProc = {};

  /// Период опроса метки (мс) = 1000 / pollHz. При pollHz ≤ 0 троттлинг
  /// отключён (обрабатываются все приёмы рекламы).
  int get _pollMs => config.pollHz > 0 ? (1000 / config.pollHz).round() : 0;

  /// Момент запуска мониторинга. В течение [_startupGraceMs] после старта
  /// открытия не отправляются («прогрев»): это гасит залп открытий в момент
  /// включения, когда в зону сразу попадает пачка меток. Подавляются только
  /// открытия; счётчики удержания при этом продолжают расти.
  DateTime? _startedAt;
  static const int _startupGraceMs = 3000;

  bool get _inStartupGrace =>
      _startedAt != null &&
      DateTime.now().difference(_startedAt!).inMilliseconds < _startupGraceMs;

  /// Живое состояние авторизованных меток для UI (по имени ТС).
  final Map<String, TagLive> _live = {};

  /// Когда последний раз открывали по метке/звонку (антидребезг открытий).
  final Map<String, DateTime> _lastTrigger = {};

  Future<void> start() async {
    if (_running) return;
    _running = true;
    _startedAt = DateTime.now();
    _emit(EventLevel.info, 'Мониторинг запущен (прогрев…)');

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
      _algo = _newAlgo();
      _lastSeen.clear();
      _lastProc.clear();
      _live.clear();
      AlgoLogger.instance.enabled = config.algoLogging;
      _absenceTimer = Timer.periodic(
          const Duration(seconds: 1), (_) => _checkAbsence());

      // Доступ по звонку (Вариант А): слушаем входящие вызовы, если включён
      // доступ по звонку и в белом списке есть запись-телефон (ключ PHONE:...).
      final hasPhone = config.whitelist
          .any((v) => (v.matchKey ?? '').toUpperCase().startsWith('PHONE:'));
      if (config.callAccessEnabled && hasPhone) {
        // Все разрешения «телефона» запрашиваем одним диалогом; для сброса
        // звонка узнаём, реально ли выдано ANSWER_PHONE_CALLS.
        final hangupOk = await IncomingCall.requestCallPermissions(
            withHangup: config.callHangup);
        _callSub = IncomingCall.instance.numbers.listen(_onIncomingCall);
        if (config.callHangup && !hangupOk) {
          _emit(
              EventLevel.warning,
              'Нет разрешения «Управление вызовами» — сброс звонка не сработает. '
              'Выдайте его кнопкой «Разрешение на сброс» или в настройках '
              'приложения (раздел «Телефон»).');
        }
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
    _algo.clear();
    _lastSeen.clear();
    _lastProc.clear();
    _live.clear();
    await AlgoLogger.instance.flushClose();
    await Hm10Sender.instance.disconnectPersistent();
    _emit(EventLevel.info, 'Мониторинг остановлен');
  }

  void updateConfig(GatewayConfig newConfig) {
    config = newConfig;
    _algo = _newAlgo();
    _lastSeen.clear();
    _lastProc.clear();
    _live.clear();
    AlgoLogger.instance.enabled = config.algoLogging;
    _emit(EventLevel.info, 'Настройки обновлены');
  }

  /// Создаёт алгоритм с параметрами из текущей конфигурации.
  ZoneAccessAlgorithm _newAlgo() => ZoneAccessAlgorithm(
        nearRssi: config.nearRssi,
        farRssi: config.farRssi,
        farHoldX: config.farHoldX,
        nearHoldY: config.nearHoldY,
      );

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
    // Алгоритм гоняется по ВСЕМ меткам: при «подходе» пакет уходит и для меток
    // не из базы (один пакет 88<MAC>), и для авторизованных (два пакета).
    // Ключ алгоритма: для авторизованного ТС — стабильное имя (устойчиво к
    // rolling-коду метки), иначе — id метки/MAC.
    final tagId = advStownId ?? advMac;
    final algoKey = vehicle != null ? 'V:${vehicle.name}' : 'T:$tagId';
    final displayName = vehicle?.name ??
        (advName.isNotEmpty ? advName : (advStownId != null ? 'STOWN' : tagId));

    final now = DateTime.now();
    _lastSeen[algoKey] = now;

    // Опрос метки с частотой config.pollHz раз/сек: лишние приёмы между тиками
    // пропускаем, чтобы счётчики A/B росли в стабильном темпе (шаг = 1000/pollHz мс).
    final lastProc = _lastProc[algoKey];
    if (lastProc != null && now.difference(lastProc).inMilliseconds < _pollMs) {
      return;
    }
    _lastProc[algoKey] = now;

    // Гистерезис зон: rssi < B → «далеко» (B++), rssi > A → «близко» (A++).
    // Открытие при удержании «близко» (A > Y); предварительный «взвод» «далеко»
    // не требуется. Подробности — в access_algorithm.dart.
    final sample = _algo.push(algoKey, rssi);

    if (vehicle != null) {
      _live[vehicle.name] = TagLive(
        zone: sample.zone.label,
        rssi: rssi,
        lastSeen: now,
        a: sample.a,
        b: sample.b,
      );
    }

    var opened = false;
    if (sample.open) {
      if (_inStartupGrace) {
        // Прогрев после старта: открытие подавляется (гасим залп открытий в
        // момент включения). Счётчики удержания при этом не сбрасываются.
        _emit(EventLevel.info, 'Прогрев: открытие $displayName пропущено');
      } else {
        // Антидребезг по cooldownSeconds (на ключ метки/ТС).
        final last = _lastTrigger[algoKey];
        if (last == null ||
            now.difference(last).inSeconds >= config.cooldownSeconds) {
          _lastTrigger[algoKey] = now;
          opened = true;
          if (vehicle != null) {
            // В базе → два пакета (01 00..00 + 88/89 <ID>).
            _trigger(vehicle, advUuid, advMac, advMajor, advMinor, advStownId,
                advKey, rssi);
          } else {
            // Не в базе → один пакет (88 <ID метки или MAC>).
            _triggerUnknown(advStownId, advMac, rssi);
          }
        }
      }
    }

    if (vehicle != null) {
      // Аудит-лог матча (сырой RSSI + зона) — для главы 3 ВКР.
      unawaited(
          GatewayLogger.instance.rssi(vehicle.name, rssi, sample.zone.label));
    }

    // Трасса алгоритма по всем меткам (если включён тумблер логирования).
    unawaited(AlgoLogger.instance.record(
      id: tagId,
      name: displayName,
      rssi: rssi,
      zone: sample.zone.label,
      a: sample.a,
      b: sample.b,
      auth: vehicle != null,
      open: opened,
    ));
  }

  /// Снимок живого состояния авторизованных меток для UI.
  Map<String, TagLive> liveSnapshot() => Map.of(_live);

  /// Периодическая проверка: метка пропала из зоны на ≥ absenceSeconds —
  /// удаляем её записи (как в спецификации алгоритма) и сбрасываем счётчики.
  void _checkAbsence() {
    final now = DateTime.now();
    final gone = _lastSeen.entries
        .where(
            (e) => now.difference(e.value).inSeconds >= config.absenceSeconds)
        .map((e) => e.key)
        .toList();
    for (final key in gone) {
      _algo.remove(key);
      _lastSeen.remove(key);
      _lastProc.remove(key);
      if (key.startsWith('V:')) _live.remove(key.substring(2));
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

    // Идентификатор 2-го пакета: ID метки (STOWN, 7 байт) либо MAC-адрес
    // (6 байт + 0). Команда открытия для BLE — cmd2 (по умолчанию 0x88).
    final identifier =
        advStownId != null ? _idBytes(advStownId) : _macBytes(advMac);
    final openCmd = _cmdByte(config.cmd2Hex, 0x88);
    // Устройство в базе → два пакета (подготовка + открытие).
    await _openFor(
        identifier: identifier, openCmd: openCmd, prep: true, info: info);
  }

  /// Открытие для метки НЕ из локальной базы: один пакет (без подготовительного
  /// 01). Идентификатор — STOWN-ID метки (если это STOWN-метка), иначе MAC.
  /// Решение «открыть/нет» остаётся за контроллером (по его собственной базе).
  Future<void> _triggerUnknown(String? advStownId, String advMac, int rssi) async {
    // Для STOWN-метки — её 7-байтный ID (на Android MAC рандомизируется),
    // иначе — MAC устройства (6 байт + 0).
    final identifier =
        advStownId != null ? _idBytes(advStownId) : _macBytes(advMac);
    final who = advStownId != null ? 'ID $advStownId' : advMac;
    _emit(EventLevel.info, 'Подход (не из базы): $who · RSSI=$rssi');
    unawaited(GatewayLogger.instance.event('OPEN_UNKNOWN', who, rssi));
    final openCmd = _cmdByte(config.cmd2Hex, 0x88);
    await _openFor(
      identifier: identifier,
      openCmd: openCmd,
      prep: false,
      info: <String, dynamic>{
        'stownId': advStownId,
        'mac': advMac,
        'source': 'ble_unknown',
        'rssi': rssi,
        'timestamp': DateTime.now().toIso8601String(),
      },
    );
  }

  /// Открытие выбранным транспортом: HTTP шлёт JSON [info]; TCP/HM-10 —
  /// 10-байтные команды (при двух — пауза 1 мс между ними). Если [prep]
  /// (устройство в базе) — перед командой открытия шлётся «подготовка»:
  /// cmd1 + нули + номер замка («01 00..00 <замок>»). Команда открытия:
  /// [openCmd] + [identifier] (ID метки/MAC, либо номер звонящего в BCD) + замок.
  Future<void> _openFor({
    required Uint8List identifier,
    required int openCmd,
    required bool prep,
    required Map<String, dynamic> info,
  }) async {
    // Открытие с пустым (нулевым) идентификатором бессмысленно: контроллер не
    // знает, кого пускать. Такой «нулевой» пакет 88/89 возникает, когда у
    // устройства нет пригодного идентификатора (MAC «00:00:…», в т.ч. своя же
    // реклама; STOWN-метка с пустым id; звонок без цифр номера). Для бинарных
    // транспортов (TCP/HM-10) подобную команду не отправляем — иначе уходит
    // «88/89 нули номер_замка». HTTP шлёт JSON с реальными полями, его не
    // касается.
    if (config.transport != GatewayTransport.http &&
        identifier.every((b) => b == 0)) {
      _emit(
          EventLevel.warning,
          'Открытие пропущено: нет идентификатора устройства — пустой пакет '
          '0x${openCmd.toRadixString(16).padLeft(2, '0')} не отправляется.');
      return;
    }
    final lock = _lockNumber();
    final packets = <Uint8List>[];
    if (prep) {
      // 1-й пакет — «подготовка», всегда с нулевым идентификатором.
      final cmd1 = _cmdByte(config.cmd1Hex, 0x01);
      packets.add(StownPacket.build(
          command: cmd1, identifier: Uint8List(kIdLen), lockNumber: lock));
    }
    packets.add(StownPacket.build(
        command: openCmd, identifier: identifier, lockNumber: lock));

    switch (config.transport) {
      case GatewayTransport.http:
        await _sendHttp(info);
        break;
      case GatewayTransport.tcp:
        await _sendStownTcp(packets);
        break;
      case GatewayTransport.hm10:
        await _sendStownHm10(packets);
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
      unawaited(IncomingCall.endCall().then((status) {
        if (status == 'ok') {
          _emit(EventLevel.info, 'Сброс звонка: ok');
        } else if (status == 'no_permission') {
          _emit(
              EventLevel.warning,
              'Сброс звонка: нет разрешения «Управление вызовами». Выдайте его '
              'кнопкой «Разрешение на сброс» или в настройках приложения.');
        } else {
          _emit(EventLevel.warning, 'Сброс звонка: $status');
        }
      }));
    }

    final advKey = 'PHONE:$last10';
    AuthorizedVehicle? vehicle;
    for (final v in config.whitelist) {
      if (v.isValid && v.matches(advKey: advKey)) {
        vehicle = v;
        break;
      }
    }
    if (_inStartupGrace) {
      _emit(EventLevel.info, 'Прогрев: открытие по звонку пропущено');
      return;
    }

    // Антидребезг по номеру звонящего (независимо от BLE-канала).
    final now = DateTime.now();
    final dedupeKey = 'CALL:$last10';
    final last = _lastTrigger[dedupeKey];
    if (last != null &&
        now.difference(last).inSeconds < config.cooldownSeconds) {
      return;
    }
    _lastTrigger[dedupeKey] = now;

    // Идентификатор пакета (байты 2-8) — номер звонящего в BCD (7 байт, 14 цифр).
    Uint8List? idBcd;
    try {
      idBcd = StownPacket.buildIdentifier(IdentifierMode.phone, last10);
    } catch (_) {
      idBcd = null;
    }
    final identifier = idBcd ?? Uint8List(kIdLen);
    final openCmd = _cmdByte(config.cmdCallHex, 0x89);

    // Номер в базе → два пакета (подготовка + 89 <номер>); не в базе → один
    // пакет (89 <номер>), решение остаётся за контроллером.
    if (vehicle != null) {
      _emit(EventLevel.success, 'Открытие (звонок): ${vehicle.name} · …$last10');
      unawaited(GatewayLogger.instance.event('OPEN_CALL', vehicle.name));
    } else {
      _emit(EventLevel.info, 'Звонок не из базы → 89 …$last10 (один пакет)');
      unawaited(GatewayLogger.instance.event('OPEN_CALL_UNKNOWN', '…$last10'));
    }

    _openFor(
        identifier: identifier,
        openCmd: openCmd,
        prep: vehicle != null,
        info: <String, dynamic>{
          'vehicle': vehicle?.name,
          'source': 'call',
          'inBase': vehicle != null,
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

  /// 7 байт идентификатора из MAC-адреса: 6 байт MAC + 1 байт нуля.
  Uint8List _macBytes(String mac) {
    final out = Uint8List(7);
    final clean = mac.replaceAll(RegExp('[^0-9A-Fa-f]'), '');
    for (var i = 0; i < 6 && i * 2 + 1 < clean.length; i++) {
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
  // TCP — две STOWN-команды: 0x01, пауза 1 мс, 0x87.
  // ------------------------------------------------------------------ //

  Future<void> _sendStownTcp(List<Uint8List> packets) async {
    final dst = '${config.tcpHost}:${config.tcpPort}';
    Socket? socket;
    try {
      socket = await Socket.connect(
        config.tcpHost,
        config.tcpPort,
        timeout: const Duration(seconds: 5),
      );
      for (var i = 0; i < packets.length; i++) {
        if (i > 0) await Future.delayed(const Duration(milliseconds: 1));
        socket.add(packets[i]);
        await socket.flush();
        _emit(EventLevel.success, 'TCP: ${_hb(packets[i])} → $dst');
      }
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
  // HM-10 — постоянное GATT-подключение, запись 0x01, пауза 1 мс, 0x87.
  // Постоянное подключение надёжнее, чем connect на каждое открытие, и
  // сосуществует со сканированием (не нужно его останавливать).
  // ------------------------------------------------------------------ //

  Future<void> _sendStownHm10(List<Uint8List> packets) async {
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
      final sent = <String>[];
      for (var i = 0; i < packets.length; i++) {
        if (i > 0) await Future.delayed(const Duration(milliseconds: 1));
        await Hm10Sender.instance.writePersistent(id, packets[i], onLog: log);
        sent.add(_hb(packets[i]));
      }
      _emit(EventLevel.success, 'HM-10: ${sent.join(' и ')} отправлены → $id');
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

/// Снимок живого состояния авторизованной метки для UI.
class TagLive {
  TagLive({
    required this.zone,
    required this.rssi,
    required this.lastSeen,
    required this.a,
    required this.b,
  });
  final String zone; // далеко | между | близко
  final int rssi; // последний сырой RSSI
  final DateTime lastSeen;
  final int a; // счётчик пребывания «близко»
  final int? b; // счётчик пребывания «далеко» (null — ещё не было «далеко»)
}
