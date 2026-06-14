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

  /// Хотя бы одно поле идентификации заполнено.
  bool get isValid =>
      (uuid != null && uuid!.isNotEmpty) ||
      (macAddress != null && macAddress!.isNotEmpty) ||
      major != null ||
      minor != null ||
      (stownId != null && stownId!.isNotEmpty) ||
      (matchKey != null && matchKey!.isNotEmpty);

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
    // Антидребезг для доступа по звонку (BLE использует КА «мёртвой зоны»).
    this.cooldownSeconds = 10,
    // Параметры «мёртвой зоны» (гистерезис) для BLE-открытия:
    this.rssiNear = -60, // P_close: RSSI ≥ этого = «рядом»
    this.rssiFar = -80, // P_dist: RSSI ≤ этого = «далеко»
    this.tCloseMs = 1000, // t_close: держаться «рядом» до открытия
    this.tFarMs = 3000, // t_dist: «далеко»/нет в зоне до перевзвода
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
  });

  // Общие
  final List<AuthorizedVehicle> whitelist;
  final int cooldownSeconds;

  // «Мёртвая зона» (гистерезис) для BLE-открытия
  final int rssiNear; // P_close
  final int rssiFar; // P_dist
  final int tCloseMs; // t_close
  final int tFarMs; // t_dist

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

  String get webhookUrl {
    final base = haUrl.replaceAll(RegExp(r'/+$'), '');
    return '$base/api/webhook/$webhookId';
  }

  Map<String, dynamic> toJson() => {
        'cooldownSeconds': cooldownSeconds,
        'rssiNear': rssiNear,
        'rssiFar': rssiFar,
        'tCloseMs': tCloseMs,
        'tFarMs': tFarMs,
        'whitelist': whitelist.map((v) => v.toJson()).toList(),
        'transport': transport.name,
        'haUrl': haUrl,
        'webhookId': webhookId,
        'tcpHost': tcpHost,
        'tcpPort': tcpPort,
        'hm10Device': hm10Device,
        'lockHex': lockHex,
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
      rssiNear: j['rssiNear'] as int? ?? -60,
      rssiFar: j['rssiFar'] as int? ?? -80,
      tCloseMs: j['tCloseMs'] as int? ?? 1000,
      tFarMs: j['tFarMs'] as int? ?? 3000,
      transport: transport,
      haUrl: j['haUrl'] as String? ?? 'http://192.168.0.10:8123',
      webhookId: j['webhookId'] as String? ?? 'gate_open',
      tcpHost: j['tcpHost'] as String? ?? '192.168.0.10',
      tcpPort: j['tcpPort'] as int? ?? 9999,
      hm10Device: j['hm10Device'] as String? ?? '',
      lockHex: j['lockHex'] as String? ?? '7702',
    );
  }

  static GatewayConfig get defaults => GatewayConfig(whitelist: []);

  GatewayConfig copyWith({
    List<AuthorizedVehicle>? whitelist,
    int? cooldownSeconds,
    int? rssiNear,
    int? rssiFar,
    int? tCloseMs,
    int? tFarMs,
    GatewayTransport? transport,
    String? haUrl,
    String? webhookId,
    String? tcpHost,
    int? tcpPort,
    String? hm10Device,
    String? lockHex,
  }) =>
      GatewayConfig(
        whitelist: whitelist ?? this.whitelist,
        cooldownSeconds: cooldownSeconds ?? this.cooldownSeconds,
        rssiNear: rssiNear ?? this.rssiNear,
        rssiFar: rssiFar ?? this.rssiFar,
        tCloseMs: tCloseMs ?? this.tCloseMs,
        tFarMs: tFarMs ?? this.tFarMs,
        transport: transport ?? this.transport,
        haUrl: haUrl ?? this.haUrl,
        webhookId: webhookId ?? this.webhookId,
        tcpHost: tcpHost ?? this.tcpHost,
        tcpPort: tcpPort ?? this.tcpPort,
        hm10Device: hm10Device ?? this.hm10Device,
        lockHex: lockHex ?? this.lockHex,
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
