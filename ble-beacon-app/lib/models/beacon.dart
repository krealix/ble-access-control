import 'dart:typed_data';

/// Все поддерживаемые форматы BLE-меток.
enum BeaconKind {
  iBeacon('iBeacon'),
  eddystoneUid('Eddy UID'),
  eddystoneUrl('Eddy URL'),
  eddystoneTlm('Eddy TLM'),
  stown('Метка'),
  custom('Custom'),
  generic('Generic');

  const BeaconKind(this.label);
  final String label;
}

/// Результат парсинга принятого BLE-объявления.
class ParsedBeacon {
  ParsedBeacon({
    required this.kind,
    required this.deviceId,
    required this.name,
    required this.rssi,
    required this.seenAt,
    required this.fields,
  });

  final BeaconKind kind;
  final String deviceId;
  final String? name;
  final int rssi;
  final DateTime seenAt;
  final Map<String, String> fields;
}

/// Сохранённый пресет генератора.
class BeaconPreset {
  BeaconPreset({
    required this.id,
    required this.name,
    required this.kind,
    required this.uuid,
    required this.major,
    required this.minor,
    required this.txPower,
    required this.namespace,
    required this.instance,
    required this.url,
    required this.serviceUuid,
    required this.manufacturerData,
    this.advName = '',
  });

  final String id;
  final String name;
  final BeaconKind kind;

  /// Имя метки в эфире (LocalName). Пусто — имя не вещается.
  /// Не работает для iBeacon (пакет полон). На Android транслируется
  /// как имя BT-адаптера.
  final String advName;

  // iBeacon
  final String uuid;
  final int major;
  final int minor;
  final int txPower;

  // Eddystone-UID
  final String namespace;
  final String instance;

  // Eddystone-URL
  final String url;

  // Custom
  final String serviceUuid;
  final String manufacturerData;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'uuid': uuid,
        'major': major,
        'minor': minor,
        'txPower': txPower,
        'namespace': namespace,
        'instance': instance,
        'url': url,
        'serviceUuid': serviceUuid,
        'manufacturerData': manufacturerData,
        'advName': advName,
      };

  static BeaconPreset fromJson(Map<String, dynamic> j) => BeaconPreset(
        id: j['id'] as String,
        name: j['name'] as String,
        kind: BeaconKind.values.firstWhere(
          (e) => e.name == j['kind'],
          orElse: () => BeaconKind.iBeacon,
        ),
        uuid: j['uuid'] as String? ?? '',
        major: j['major'] as int? ?? 0,
        minor: j['minor'] as int? ?? 0,
        txPower: j['txPower'] as int? ?? -59,
        namespace: j['namespace'] as String? ?? '',
        instance: j['instance'] as String? ?? '',
        url: j['url'] as String? ?? '',
        serviceUuid: j['serviceUuid'] as String? ?? '',
        manufacturerData: j['manufacturerData'] as String? ?? '',
        advName: j['advName'] as String? ?? '',
      );

  BeaconPreset copyWith({
    String? name,
    BeaconKind? kind,
    String? uuid,
    int? major,
    int? minor,
    int? txPower,
    String? namespace,
    String? instance,
    String? url,
    String? serviceUuid,
    String? manufacturerData,
    String? advName,
  }) =>
      BeaconPreset(
        id: id,
        name: name ?? this.name,
        kind: kind ?? this.kind,
        uuid: uuid ?? this.uuid,
        major: major ?? this.major,
        minor: minor ?? this.minor,
        txPower: txPower ?? this.txPower,
        namespace: namespace ?? this.namespace,
        instance: instance ?? this.instance,
        url: url ?? this.url,
        serviceUuid: serviceUuid ?? this.serviceUuid,
        manufacturerData: manufacturerData ?? this.manufacturerData,
        advName: advName ?? this.advName,
      );
}

/// Утилиты для работы с hex и UUID.
class HexUtils {
  static Uint8List hexToBytes(String hex) {
    final clean = hex.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
    return Uint8List.fromList([
      for (var i = 0; i + 1 < clean.length; i += 2)
        int.parse(clean.substring(i, i + 2), radix: 16),
    ]);
  }

  static String bytesToHex(List<int> bytes) => bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join();

  static String formatHexSpaced(List<int> bytes) => bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');

  static String uuidNoDashes(String uuid) => uuid.replaceAll('-', '');

  static String formatUuidWithDashes(String hex) {
    final h = hex.toLowerCase();
    if (h.length != 32) return hex;
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20, 32)}';
  }
}
