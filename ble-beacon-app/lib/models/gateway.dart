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
  });

  final String name;
  final String? uuid;
  final String? macAddress;
  final int? major;
  final int? minor;

  /// Идентификатор STOWN-метки (hex 7 байт) — сверяется напрямую с полем ID
  /// 10-байтного пакета, в любой обёртке (manufacturer/service/iBeacon).
  final String? stownId;

  /// Хотя бы одно поле идентификации заполнено.
  bool get isValid =>
      (uuid != null && uuid!.isNotEmpty) ||
      (macAddress != null && macAddress!.isNotEmpty) ||
      major != null ||
      minor != null ||
      (stownId != null && stownId!.isNotEmpty);

  /// OR-матчинг: возвращает true если хотя бы одно непустое поле
  /// совпадает с соответствующим полем рекламы.
  bool matches({
    String? advUuid,
    String? advMac,
    int? advMajor,
    int? advMinor,
    String? advStownId,
  }) {
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
  }) {
    final matched = <String>[];
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
    return parts.isEmpty ? '(пусто)' : parts.join('  ');
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        if (uuid != null) 'uuid': uuid,
        if (macAddress != null) 'macAddress': macAddress,
        if (major != null) 'major': major,
        if (minor != null) 'minor': minor,
        if (stownId != null) 'stownId': stownId,
      };

  static AuthorizedVehicle fromJson(Map<String, dynamic> j) {
    return AuthorizedVehicle(
      name: j['name'] as String? ?? '',
      uuid: j['uuid'] as String?,
      macAddress: j['macAddress'] as String?,
      major: j['major'] as int?,
      minor: j['minor'] as int?,
      stownId: j['stownId'] as String?,
    );
  }
}

/// Транспорт для отправки сигнала «открыть».
enum GatewayTransport {
  http,   // HTTP POST на HA webhook
  tcp,    // Raw TCP-сокет на хост:порт
  mqtt,   // MQTT publish на брокер/топик
}

/// Формат данных при TCP-передаче.
enum TcpPayloadFormat {
  json,   // JSON-строка + \n
  text,   // Текст-шаблон с {vehicle}, {mac} и т.п.
  hex,    // Фиксированные hex-байты
}

/// Конфигурация шлюзового телефона у шлагбаума.
class GatewayConfig {
  GatewayConfig({
    required this.rssiThreshold,
    required this.cooldownSeconds,
    required this.samplesRequired,
    required this.whitelist,
    this.transport = GatewayTransport.http,
    // HTTP
    this.haUrl = 'http://192.168.0.10:8123',
    this.webhookId = 'gate_open',
    // TCP
    this.tcpHost = '192.168.0.10',
    this.tcpPort = 9999,
    this.tcpPayloadFormat = TcpPayloadFormat.json,
    this.tcpPayloadTemplate = 'OPEN {vehicle}\\n',
    // MQTT
    this.mqttHost = '192.168.0.10',
    this.mqttPort = 1883,
    this.mqttTopic = 'home/gate/open',
    this.mqttUsername = '',
    this.mqttPassword = '',
  });

  // Общие
  final int rssiThreshold;
  final int cooldownSeconds;
  final int samplesRequired;
  final List<AuthorizedVehicle> whitelist;

  // Транспорт
  final GatewayTransport transport;

  // HTTP
  final String haUrl;
  final String webhookId;

  // TCP
  final String tcpHost;
  final int tcpPort;
  final TcpPayloadFormat tcpPayloadFormat;
  final String tcpPayloadTemplate;

  // MQTT
  final String mqttHost;
  final int mqttPort;
  final String mqttTopic;
  final String mqttUsername;
  final String mqttPassword;

  String get webhookUrl {
    final base = haUrl.replaceAll(RegExp(r'/+$'), '');
    return '$base/api/webhook/$webhookId';
  }

  Map<String, dynamic> toJson() => {
        'rssiThreshold': rssiThreshold,
        'cooldownSeconds': cooldownSeconds,
        'samplesRequired': samplesRequired,
        'whitelist': whitelist.map((v) => v.toJson()).toList(),
        'transport': transport.name,
        'haUrl': haUrl,
        'webhookId': webhookId,
        'tcpHost': tcpHost,
        'tcpPort': tcpPort,
        'tcpPayloadFormat': tcpPayloadFormat.name,
        'tcpPayloadTemplate': tcpPayloadTemplate,
        'mqttHost': mqttHost,
        'mqttPort': mqttPort,
        'mqttTopic': mqttTopic,
        'mqttUsername': mqttUsername,
        'mqttPassword': mqttPassword,
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
      );
    }).toList();

    GatewayTransport transport;
    try {
      transport = GatewayTransport.values
          .firstWhere((t) => t.name == (j['transport'] as String? ?? 'http'));
    } catch (_) {
      transport = GatewayTransport.http;
    }
    TcpPayloadFormat tcpFmt;
    try {
      tcpFmt = TcpPayloadFormat.values
          .firstWhere((f) => f.name == (j['tcpPayloadFormat'] as String? ?? 'json'));
    } catch (_) {
      tcpFmt = TcpPayloadFormat.json;
    }

    return GatewayConfig(
      rssiThreshold: j['rssiThreshold'] as int? ?? -65,
      cooldownSeconds: j['cooldownSeconds'] as int? ?? 10,
      samplesRequired: j['samplesRequired'] as int? ?? 2,
      whitelist: whitelist,
      transport: transport,
      haUrl: j['haUrl'] as String? ?? 'http://192.168.0.10:8123',
      webhookId: j['webhookId'] as String? ?? 'gate_open',
      tcpHost: j['tcpHost'] as String? ?? '192.168.0.10',
      tcpPort: j['tcpPort'] as int? ?? 9999,
      tcpPayloadFormat: tcpFmt,
      tcpPayloadTemplate:
          j['tcpPayloadTemplate'] as String? ?? 'OPEN {vehicle}\\n',
      mqttHost: j['mqttHost'] as String? ?? '192.168.0.10',
      mqttPort: j['mqttPort'] as int? ?? 1883,
      mqttTopic: j['mqttTopic'] as String? ?? 'home/gate/open',
      mqttUsername: j['mqttUsername'] as String? ?? '',
      mqttPassword: j['mqttPassword'] as String? ?? '',
    );
  }

  static GatewayConfig get defaults => GatewayConfig(
        rssiThreshold: -65,
        cooldownSeconds: 10,
        samplesRequired: 2,
        whitelist: [],
      );

  GatewayConfig copyWith({
    int? rssiThreshold,
    int? cooldownSeconds,
    int? samplesRequired,
    List<AuthorizedVehicle>? whitelist,
    GatewayTransport? transport,
    String? haUrl,
    String? webhookId,
    String? tcpHost,
    int? tcpPort,
    TcpPayloadFormat? tcpPayloadFormat,
    String? tcpPayloadTemplate,
    String? mqttHost,
    int? mqttPort,
    String? mqttTopic,
    String? mqttUsername,
    String? mqttPassword,
  }) =>
      GatewayConfig(
        rssiThreshold: rssiThreshold ?? this.rssiThreshold,
        cooldownSeconds: cooldownSeconds ?? this.cooldownSeconds,
        samplesRequired: samplesRequired ?? this.samplesRequired,
        whitelist: whitelist ?? this.whitelist,
        transport: transport ?? this.transport,
        haUrl: haUrl ?? this.haUrl,
        webhookId: webhookId ?? this.webhookId,
        tcpHost: tcpHost ?? this.tcpHost,
        tcpPort: tcpPort ?? this.tcpPort,
        tcpPayloadFormat: tcpPayloadFormat ?? this.tcpPayloadFormat,
        tcpPayloadTemplate: tcpPayloadTemplate ?? this.tcpPayloadTemplate,
        mqttHost: mqttHost ?? this.mqttHost,
        mqttPort: mqttPort ?? this.mqttPort,
        mqttTopic: mqttTopic ?? this.mqttTopic,
        mqttUsername: mqttUsername ?? this.mqttUsername,
        mqttPassword: mqttPassword ?? this.mqttPassword,
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
