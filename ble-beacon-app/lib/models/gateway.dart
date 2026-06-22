/// Нормализованный UUID — uppercase, без дефисов и пробелов.
String normalizeUuid(String? s) {
  if (s == null) return '';
  return s.toUpperCase().replaceAll('-', '').replaceAll(' ', '');
}

/// Нормализованный MAC — uppercase, без двоеточий/дефисов/пробелов.
String normalizeMac(String? s) {
  if (s == null) return '';
  return s
      .toUpperCase()
      .replaceAll(':', '')
      .replaceAll('-', '')
      .replaceAll(' ', '');
}

/// Нормализованный STOWN-идентификатор (hex, 7 байт) — uppercase, без разделителей.
String normalizeId(String? s) {
  if (s == null) return '';
  return s
      .toUpperCase()
      .replaceAll(':', '')
      .replaceAll('-', '')
      .replaceAll(' ', '');
}

/// Запись из белого списка авторизованных машин.
///
/// Все идентификационные поля опциональны. Используется OR-матчинг:
/// если хотя бы одно непустое поле совпадает с advertisement'ом — это «своё» ТС.
class AuthorizedVehicle {
  AuthorizedVehicle({
    required this.name,
    this.uuid,
    this.macAddress,
    this.major,
    this.minor,
    this.stownId,
    this.matchKey,
    this.secret,
  });

  final String name;
  final String? uuid;
  final String? macAddress;
  final int? major;
  final int? minor;

  /// Идентификатор STOWN-метки (hex 7 байт) — сверяется напрямую с полем ID
  /// 10-байтного пакета, в любой обёртке (manufacturer/service/iBeacon).
  final String? stownId;

  /// Ключ из «Сканера»: для STOWN-метки — "STOWN:ИМЯ", иначе — MAC-адрес.
  /// Сверяется с ключом, который шлюз вычисляет по рекламе.
  final String? matchKey;

  /// Секрет (hex) для динамической метки (rolling-code). Сверка кода — в
  /// мониторе (RollingCode.matches), т.к. зависит от времени.
  final String? secret;

  /// Хотя бы одно поле идентификации заполнено.
  bool get isValid =>
      (uuid != null && uuid!.isNotEmpty) ||
      (macAddress != null && macAddress!.isNotEmpty) ||
      major != null ||
      minor != null ||
      (stownId != null && stownId!.isNotEmpty) ||
      (matchKey != null && matchKey!.isNotEmpty) ||
      (secret != null && secret!.isNotEmpty);

  /// OR-матчинг: возвращает true если хотя бы одно непустое поле
  /// совпадает с соответствующим полем рекламы.
  bool matches({
    String? advUuid,
    String? advMac,
    int? advMajor,
    int? advMinor,
    String? advStownId,
    String? advKey,
  }) {
    if (matchKey != null && matchKey!.isNotEmpty && advKey != null) {
      if (matchKey!.toUpperCase() == advKey.toUpperCase()) return true;
    }
    if (uuid != null && uuid!.isNotEmpty) {
      if (advUuid != null && normalizeUuid(uuid) == normalizeUuid(advUuid)) {
        return true;
      }
    }
    if (macAddress != null && macAddress!.isNotEmpty) {
      if (advMac != null && normalizeMac(macAddress) == normalizeMac(advMac)) {
        return true;
      }
    }
    if (major != null && advMajor != null && major == advMajor) {
      return true;
    }
    if (minor != null && advMinor != null && minor == advMinor) {
      return true;
    }
    if (stownId != null && stownId!.isNotEmpty) {
      if (advStownId != null && normalizeId(stownId) == normalizeId(advStownId)) {
        return true;
      }
    }
    return false;
  }

  /// Какие конкретно поля совпали — для журнала событий.
  String explainMatch({
    String? advUuid,
    String? advMac,
    int? advMajor,
    int? advMinor,
    String? advStownId,
    String? advKey,
  }) {
    final matched = <String>[];
    if (matchKey != null &&
        matchKey!.isNotEmpty &&
        advKey != null &&
        matchKey!.toUpperCase() == advKey.toUpperCase()) {
      matched.add(matchKey!.startsWith('STOWN:')
          ? 'Имя'
          : matchKey!.startsWith('PHONE:')
              ? 'Телефон'
              : 'MAC');
    }
    if (uuid != null &&
        uuid!.isNotEmpty &&
        advUuid != null &&
        normalizeUuid(uuid) == normalizeUuid(advUuid)) {
      matched.add('UUID');
    }
    if (macAddress != null &&
        macAddress!.isNotEmpty &&
        advMac != null &&
        normalizeMac(macAddress) == normalizeMac(advMac)) {
      matched.add('MAC');
    }
    if (major != null && advMajor != null && major == advMajor) {
      matched.add('Major=$advMajor');
    }
    if (minor != null && advMinor != null && minor == advMinor) {
      matched.add('Minor=$advMinor');
    }
    if (stownId != null &&
        stownId!.isNotEmpty &&
        advStownId != null &&
        normalizeId(stownId) == normalizeId(advStownId)) {
      matched.add('ID');
    }
    return matched.isEmpty ? '—' : matched.join(' + ');
  }

  /// Короткая сводка полей для UI.
  String get summary {
    final parts = <String>[];
    if (uuid != null && uuid!.isNotEmpty) {
      final n = normalizeUuid(uuid);
      parts.add('UUID=${n.substring(0, n.length.clamp(0, 8))}…');
    }
    if (macAddress != null && macAddress!.isNotEmpty) {
      parts.add('MAC=$macAddress');
    }
    if (major != null) parts.add('Major=$major');
    if (minor != null) parts.add('Minor=$minor');
    if (stownId != null && stownId!.isNotEmpty) parts.add('ID=$stownId');
    if (matchKey != null && matchKey!.isNotEmpty) parts.add(matchKey!);
    if (secret != null && secret!.isNotEmpty) parts.add('rolling');
    return parts.isEmpty ? '(пусто)' : parts.join('  ');
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        if (uuid != null) 'uuid': uuid,
        if (macAddress != null) 'macAddress': macAddress,
        if (major != null) 'major': major,
        if (minor != null) 'minor': minor,
        if (stownId != null) 'stownId': stownId,
        if (matchKey != null) 'matchKey': matchKey,
        if (secret != null) 'secret': secret,
      };

  static AuthorizedVehicle fromJson(Map<String, dynamic> j) {
    return AuthorizedVehicle(
      name: j['name'] as String? ?? '',
      uuid: j['uuid'] as String?,
      macAddress: j['macAddress'] as String?,
      major: j['major'] as int?,
      minor: j['minor'] as int?,
      stownId: j['stownId'] as String?,
      matchKey: j['matchKey'] as String?,
      secret: j['secret'] as String?,
    );
  }
}

/// Транспорт для отправки команды «открыть».
enum GatewayTransport {
  http,   // HTTP POST на HA webhook (JSON-уведомление)
  tcp,    // Raw TCP-сокет: 10-байтные STOWN-пакеты (01, пауза, 87)
  hm10,   // Прямая запись STOWN-пакетов в HM-10 по GATT (FFE1)
}

/// Конфигурация шлюзового телефона у шлагбаума.
class GatewayConfig {
  GatewayConfig({
    required this.whitelist,
    // Антидребезг для доступа по звонку.
    this.cooldownSeconds = 10,
    // Параметры алгоритма доступа по гистерезису зон сигнала (BLE):
    this.nearRssi = -65, // A: RSSI > этого = «близко»
    this.farRssi = -85, // B: RSSI < этого = «далеко»
    this.farHoldX = 3, // X: замеров «далеко» подряд для взвода
    this.nearHoldY = 3, // Y: замеров «близко» подряд для выдачи доступа
    this.absenceSeconds = 5, // нет метки в зоне столько секунд → удалить записи
    this.pollHz = 4, // частота прогона алгоритма по метке, раз/сек (шаг A/B)
    // Логировать трассу алгоритма по всем меткам в отдельный файл.
    this.algoLogging = false,
    this.transport = GatewayTransport.http,
    // HTTP
    this.haUrl = 'http://192.168.0.10:8123',
    this.webhookId = 'gate_open',
    // TCP (отправка STOWN-команд на хост:порт)
    this.tcpHost = '192.168.0.10',
    this.tcpPort = 9999,
    // HM-10 (прямая запись по GATT)
    this.hm10Device = '',
    // Общий для TCP и HM-10: номер замка (hex), напр. 7702
    this.lockHex = '7702',
    // Командные байты пакета (hex). cmd1 — «подготовка» (1-й пакет);
    // cmd2 — «открыть» для BLE (MAC/ID метки); cmdCall — «открыть» для звонка.
    this.cmd1Hex = '01',
    this.cmd2Hex = '88',
    this.cmdCallHex = '89',
    // В 1-м пакете идентификатор (байты 2-8) заполнять нулями.
    this.firstZeroId = true,
    // Доступ по звонку (Вариант А): открытие при входящем из базы.
    this.callAccessEnabled = true,
    // Автоматически сбрасывать входящий звонок после чтения номера.
    this.callHangup = true,
  });

  // Общие
  final List<AuthorizedVehicle> whitelist;
  final int cooldownSeconds;

  // Алгоритм доступа по гистерезису зон сигнала (BLE)
  final int nearRssi; // A: rssi > nearRssi → «близко»
  final int farRssi; // B: rssi < farRssi → «далеко»
  final int farHoldX; // X: порог удержания «далеко» (взвод)
  final int nearHoldY; // Y: порог удержания «близко» (выдача)
  final int absenceSeconds; // метка пропала из зоны → удалить записи

  /// Частота опроса меток алгоритмом, раз/сек (Гц). Один «тик» = шаг счётчиков
  /// A/B; период троттлинга = 1000 / pollHz мс. По умолчанию 4 раз/сек (250 мс).
  final int pollHz;

  /// Логировать трассу алгоритма по всем меткам в отдельный файл.
  final bool algoLogging;

  // Транспорт
  final GatewayTransport transport;

  // HTTP
  final String haUrl;
  final String webhookId;

  // TCP
  final String tcpHost;
  final int tcpPort;

  // HM-10: адрес (MAC) или имя целевого модуля
  final String hm10Device;

  // Номер замка (hex) для STOWN-команд TCP/HM-10
  final String lockHex;

  // Командные байты (hex) и режим нулевого идентификатора в 1-м пакете
  final String cmd1Hex;
  final String cmd2Hex; // «открыть» для BLE (MAC/ID метки), напр. 88
  final String cmdCallHex; // «открыть» для доступа по звонку, напр. 89
  final bool firstZeroId;

  // Доступ по звонку
  final bool callAccessEnabled;
  final bool callHangup;

  String get webhookUrl {
    final base = haUrl.replaceAll(RegExp(r'/+$'), '');
    return '$base/api/webhook/$webhookId';
  }

  Map<String, dynamic> toJson() => {
        'cooldownSeconds': cooldownSeconds,
        'nearRssi': nearRssi,
        'farRssi': farRssi,
        'farHoldX': farHoldX,
        'nearHoldY': nearHoldY,
        'absenceSeconds': absenceSeconds,
        'pollHz': pollHz,
        'algoLogging': algoLogging,
        'whitelist': whitelist.map((v) => v.toJson()).toList(),
        'transport': transport.name,
        'haUrl': haUrl,
        'webhookId': webhookId,
        'tcpHost': tcpHost,
        'tcpPort': tcpPort,
        'hm10Device': hm10Device,
        'lockHex': lockHex,
        'cmd1Hex': cmd1Hex,
        'cmd2Hex': cmd2Hex,
        'cmdCallHex': cmdCallHex,
        'firstZeroId': firstZeroId,
        'callAccessEnabled': callAccessEnabled,
        'callHangup': callHangup,
      };

  /// Загрузка с учётом старого формата (где был beaconUuid на уровне config).
  static GatewayConfig fromJson(Map<String, dynamic> j) {
    final legacyUuid = j['beaconUuid'] as String? ?? '';
    final rawWhitelist = (j['whitelist'] as List? ?? []);
    final whitelist = rawWhitelist.map((e) {
      final map = e as Map<String, dynamic>;
      final hasUuid = map['uuid'] != null && (map['uuid'] as String).isNotEmpty;
      return AuthorizedVehicle(
        name: map['name'] as String? ?? '',
        uuid: hasUuid
            ? map['uuid'] as String?
            : (legacyUuid.isNotEmpty ? legacyUuid : null),
        macAddress: map['macAddress'] as String?,
        major: map['major'] as int?,
        minor: map['minor'] as int?,
        stownId: map['stownId'] as String?,
        matchKey: map['matchKey'] as String?,
        secret: map['secret'] as String?,
      );
    }).toList();

    GatewayTransport transport;
    try {
      transport = GatewayTransport.values
          .firstWhere((t) => t.name == (j['transport'] as String? ?? 'http'));
    } catch (_) {
      transport = GatewayTransport.http;
    }

    return GatewayConfig(
      whitelist: whitelist,
      cooldownSeconds: j['cooldownSeconds'] as int? ?? 10,
      // Новые ключи; при их отсутствии берём старые (rssiNear/rssiFar) либо дефолты.
      nearRssi: j['nearRssi'] as int? ?? j['rssiNear'] as int? ?? -65,
      farRssi: j['farRssi'] as int? ?? j['rssiFar'] as int? ?? -85,
      farHoldX: j['farHoldX'] as int? ?? 3,
      nearHoldY: j['nearHoldY'] as int? ?? 3,
      absenceSeconds: j['absenceSeconds'] as int? ?? 5,
      pollHz: j['pollHz'] as int? ?? 4,
      algoLogging: j['algoLogging'] as bool? ?? false,
      transport: transport,
      haUrl: j['haUrl'] as String? ?? 'http://192.168.0.10:8123',
      webhookId: j['webhookId'] as String? ?? 'gate_open',
      tcpHost: j['tcpHost'] as String? ?? '192.168.0.10',
      tcpPort: j['tcpPort'] as int? ?? 9999,
      hm10Device: j['hm10Device'] as String? ?? '',
      lockHex: j['lockHex'] as String? ?? '7702',
      cmd1Hex: j['cmd1Hex'] as String? ?? '01',
      cmd2Hex: j['cmd2Hex'] as String? ?? '88',
      cmdCallHex: j['cmdCallHex'] as String? ?? '89',
      firstZeroId: j['firstZeroId'] as bool? ?? true,
      callAccessEnabled: j['callAccessEnabled'] as bool? ?? true,
      callHangup: j['callHangup'] as bool? ?? true,
    );
  }

  static GatewayConfig get defaults => GatewayConfig(whitelist: []);

  GatewayConfig copyWith({
    List<AuthorizedVehicle>? whitelist,
    int? cooldownSeconds,
    int? nearRssi,
    int? farRssi,
    int? farHoldX,
    int? nearHoldY,
    int? absenceSeconds,
    int? pollHz,
    bool? algoLogging,
    GatewayTransport? transport,
    String? haUrl,
    String? webhookId,
    String? tcpHost,
    int? tcpPort,
    String? hm10Device,
    String? lockHex,
    String? cmd1Hex,
    String? cmd2Hex,
    String? cmdCallHex,
    bool? firstZeroId,
    bool? callAccessEnabled,
    bool? callHangup,
  }) =>
      GatewayConfig(
        whitelist: whitelist ?? this.whitelist,
        cooldownSeconds: cooldownSeconds ?? this.cooldownSeconds,
        nearRssi: nearRssi ?? this.nearRssi,
        farRssi: farRssi ?? this.farRssi,
        farHoldX: farHoldX ?? this.farHoldX,
        nearHoldY: nearHoldY ?? this.nearHoldY,
        absenceSeconds: absenceSeconds ?? this.absenceSeconds,
        pollHz: pollHz ?? this.pollHz,
        algoLogging: algoLogging ?? this.algoLogging,
        transport: transport ?? this.transport,
        haUrl: haUrl ?? this.haUrl,
        webhookId: webhookId ?? this.webhookId,
        tcpHost: tcpHost ?? this.tcpHost,
        tcpPort: tcpPort ?? this.tcpPort,
        hm10Device: hm10Device ?? this.hm10Device,
        lockHex: lockHex ?? this.lockHex,
        cmd1Hex: cmd1Hex ?? this.cmd1Hex,
        cmd2Hex: cmd2Hex ?? this.cmd2Hex,
        cmdCallHex: cmdCallHex ?? this.cmdCallHex,
        firstZeroId: firstZeroId ?? this.firstZeroId,
        callAccessEnabled: callAccessEnabled ?? this.callAccessEnabled,
        callHangup: callHangup ?? this.callHangup,
      );
}

enum EventLevel { info, success, warning, error }

class GatewayEvent {
  GatewayEvent({
    required this.timestamp,
    required this.level,
    required this.message,
  });

  final DateTime timestamp;
  final EventLevel level;
  final String message;
}
