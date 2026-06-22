/// Формирование и разбор 10-байтного пакета STOWN-шлагбаума.
///
/// Формат (как на схеме: 87 00 00 00 00 00 00 00 77 02):
///   байт  0      команда открытия (0x87 или 0x01)
///   байты 1..7   идентификатор устройства (7 байт)
///   байты 8..9   номер замка, big-endian uint16
library;

import 'dart:math';
import 'dart:typed_data';

const int kPacketLen = 10;
const int kIdLen = 7;
const int kCmdOpen87 = 0x87;
const int kCmdOpen01 = 0x01;

enum IdentifierMode { deviceId, mac, uuid, phone, imei }

extension IdentifierModeName on IdentifierMode {
  String get storageName => switch (this) {
        IdentifierMode.deviceId => 'device_id',
        IdentifierMode.mac => 'mac',
        IdentifierMode.uuid => 'uuid',
        IdentifierMode.phone => 'phone',
        IdentifierMode.imei => 'imei',
      };

  static IdentifierMode fromName(String? s) => switch (s) {
        'mac' => IdentifierMode.mac,
        'uuid' => IdentifierMode.uuid,
        'phone' => IdentifierMode.phone,
        'imei' => IdentifierMode.imei,
        _ => IdentifierMode.deviceId,
      };
}

/// Способ обёртки 10 байт в BLE-рекламу.
enum WrapperFormat { manufacturer, service, ibeacon }

extension WrapperFormatName on WrapperFormat {
  String get storageName => switch (this) {
        WrapperFormat.manufacturer => 'manufacturer',
        WrapperFormat.service => 'service',
        WrapperFormat.ibeacon => 'ibeacon',
      };

  static WrapperFormat fromName(String? s) => switch (s) {
        'service' => WrapperFormat.service,
        'ibeacon' => WrapperFormat.ibeacon,
        _ => WrapperFormat.manufacturer,
      };
}

class StownPacket {
  /// Случайный 7-байтный Device ID как hex-строка (14 символов).
  static String generateDeviceId() {
    final rng = Random.secure();
    final bytes = List<int>.generate(kIdLen, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
  }

  static Uint8List _hexToBytes(String s) {
    final clean = s
        .replaceAll(' ', '')
        .replaceAll(':', '')
        .replaceAll('-', '');
    final out = <int>[];
    for (var i = 0; i + 1 < clean.length; i += 2) {
      out.add(int.parse(clean.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(out);
  }

  /// Ровно 7 байт идентификатора по режиму.
  /// Бросает [FormatException] при некорректном значении.
  static Uint8List buildIdentifier(IdentifierMode mode, String value) {
    switch (mode) {
      case IdentifierMode.deviceId:
        var raw = _hexToBytes(value);
        if (raw.length < kIdLen) {
          raw = Uint8List.fromList([...raw, ...List.filled(kIdLen - raw.length, 0)]);
        }
        return Uint8List.fromList(raw.sublist(0, kIdLen));
      case IdentifierMode.mac:
        final raw = _hexToBytes(value);
        if (raw.length != 6) {
          throw const FormatException('MAC должен быть 6 байт (12 hex)');
        }
        return Uint8List.fromList([...raw, 0x00]); // 6 + 1 padding
      case IdentifierMode.uuid:
        final raw = _hexToBytes(value);
        if (raw.length < kIdLen) {
          throw const FormatException('UUID слишком короткий (нужно ≥ 7 байт)');
        }
        return Uint8List.fromList(raw.sublist(0, kIdLen));
      case IdentifierMode.phone:
      case IdentifierMode.imei:
        // Номер телефона / IMEI → BCD: каждая цифра в одном полубайте,
        // 7 байт = 14 цифр. Дополняем слева нулями.
        return _bcdEncode14(value);
    }
  }

  /// Максимум цифр, помещающихся в 7 байт BCD (по 2 цифры на байт).
  static const int kBcdMaxDigits = kIdLen * 2; // 14

  /// Кодирует строку цифр в 7 байт BCD: слева дополняется нулями до 14 цифр,
  /// каждая пара цифр → один байт (старший полубайт — первая цифра).
  static Uint8List _bcdEncode14(String value) {
    final digits = value.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) {
      throw const FormatException('Введите цифры');
    }
    if (digits.length > kBcdMaxDigits) {
      throw const FormatException('Не более 14 цифр');
    }
    final padded = digits.padLeft(kBcdMaxDigits, '0'); // 14 символов
    final out = Uint8List(kIdLen);
    for (var i = 0; i < kIdLen; i++) {
      final hi = padded.codeUnitAt(i * 2) - 0x30;
      final lo = padded.codeUnitAt(i * 2 + 1) - 0x30;
      out[i] = (hi << 4) | lo;
    }
    return out;
  }

  /// Обратное преобразование 7-байт BCD в строку цифр (для отладки/UI).
  /// Ведущие нули убираются.
  static String identifierToPhone(Uint8List id) {
    final sb = StringBuffer();
    for (final b in id) {
      sb.write(((b >> 4) & 0xF).toString());
      sb.write((b & 0xF).toString());
    }
    final s = sb.toString().replaceFirst(RegExp(r'^0+'), '');
    return s.isEmpty ? '0' : s;
  }

  /// Парсит номер замка: '7702' / '0x7702' → int (трактуем как hex).
  static int parseLockNumber(String lock) {
    var s = lock.trim().toLowerCase();
    if (s.startsWith('0x')) s = s.substring(2);
    final value = int.parse(s, radix: 16);
    if (value < 0 || value > 0xFFFF) {
      throw FormatException('номер замка вне диапазона: $value');
    }
    return value;
  }

  /// Собирает финальные 10 байт.
  static Uint8List build({
    required int command,
    required Uint8List identifier,
    required int lockNumber,
  }) {
    if (identifier.length != kIdLen) {
      throw FormatException('identifier должен быть $kIdLen байт');
    }
    if (lockNumber < 0 || lockNumber > 0xFFFF) {
      throw FormatException('lockNumber вне диапазона: $lockNumber');
    }
    return Uint8List.fromList([
      command & 0xFF,
      ...identifier,
      (lockNumber >> 8) & 0xFF,
      lockNumber & 0xFF,
    ]);
  }

  /// '87 00 00 00 00 00 00 00 77 02'
  static String format(Uint8List packet) =>
      packet.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');

  // ---- Декодирование (для сканера) ----

  static bool looksLikeStown(List<int> data) =>
      data.length == kPacketLen && (data[0] == kCmdOpen87 || data[0] == kCmdOpen01);

  static DecodedPacket? decode(List<int> data) {
    if (data.length != kPacketLen) return null;
    final command = data[0];
    final identifier = data.sublist(1, 1 + kIdLen);
    final lock = (data[8] << 8) | data[9];
    return DecodedPacket(command: command, identifier: identifier, lockNumber: lock);
  }
}

class DecodedPacket {
  DecodedPacket({
    required this.command,
    required this.identifier,
    required this.lockNumber,
  });

  final int command;
  final List<int> identifier;
  final int lockNumber;

  String get commandHex => '0x${command.toRadixString(16).padLeft(2, '0').toUpperCase()}';
  String get identifierHex =>
      identifier.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
  String get lockHex => '0x${lockNumber.toRadixString(16).padLeft(4, '0').toUpperCase()}';
}

/// Замок: имя + hex-номер.
class GateLock {
  GateLock({required this.name, required this.number});
  final String name;
  final String number; // hex-строка, напр. "7702"

  Map<String, dynamic> toJson() => {'name': name, 'number': number};
  static GateLock fromJson(Map<String, dynamic> j) =>
      GateLock(name: j['name'] as String? ?? '', number: j['number'] as String? ?? '');
}

/// Конфигурация STOWN-метки.
class StownConfig {
  StownConfig({
    this.command = kCmdOpen87,
    this.identifierMode = IdentifierMode.deviceId,
    this.deviceId = '',
    this.macValue = '',
    this.uuidValue = '',
    this.phoneValue = '',
    this.imeiValue = '',
    this.locks = const [],
    this.selectedLock = 0,
    this.wrapper = WrapperFormat.manufacturer,
    this.companyId = 0xFFFF,
    this.serviceUuid = 'FFF0',
    this.tagName = '',
    this.rolling = false,
    this.secretHex = '',
  });

  final int command;
  final IdentifierMode identifierMode;
  final String deviceId;
  final String macValue;
  final String uuidValue;
  final String phoneValue;
  final String imeiValue;
  final List<GateLock> locks;
  final int selectedLock;
  final WrapperFormat wrapper;
  final int companyId;
  final String serviceUuid;

  /// Имя метки (LocalName в рекламе) — показывается в сканере.
  final String tagName;

  /// Динамический идентификатор (rolling-code) вместо статичного.
  final bool rolling;

  /// Секрет (hex) для rolling-code.
  final String secretHex;

  String identifierValueFor(IdentifierMode mode) => switch (mode) {
        IdentifierMode.deviceId => deviceId,
        IdentifierMode.mac => macValue,
        IdentifierMode.uuid => uuidValue,
        IdentifierMode.phone => phoneValue,
        IdentifierMode.imei => imeiValue,
      };

  Map<String, dynamic> toJson() => {
        'command': command,
        'identifierMode': identifierMode.storageName,
        'deviceId': deviceId,
        'macValue': macValue,
        'uuidValue': uuidValue,
        'phoneValue': phoneValue,
        'imeiValue': imeiValue,
        'locks': locks.map((l) => l.toJson()).toList(),
        'selectedLock': selectedLock,
        'wrapper': wrapper.storageName,
        'companyId': companyId,
        'serviceUuid': serviceUuid,
        'tagName': tagName,
        'rolling': rolling,
        'secretHex': secretHex,
      };

  static StownConfig fromJson(Map<String, dynamic> j) => StownConfig(
        command: j['command'] as int? ?? kCmdOpen87,
        identifierMode: IdentifierModeName.fromName(j['identifierMode'] as String?),
        deviceId: j['deviceId'] as String? ?? '',
        macValue: j['macValue'] as String? ?? '',
        uuidValue: j['uuidValue'] as String? ?? '',
        phoneValue: j['phoneValue'] as String? ?? '',
        imeiValue: j['imeiValue'] as String? ?? '',
        locks: (j['locks'] as List? ?? [])
            .map((e) => GateLock.fromJson(e as Map<String, dynamic>))
            .toList(),
        selectedLock: j['selectedLock'] as int? ?? 0,
        wrapper: WrapperFormatName.fromName(j['wrapper'] as String?),
        companyId: j['companyId'] as int? ?? 0xFFFF,
        serviceUuid: j['serviceUuid'] as String? ?? 'FFF0',
        tagName: j['tagName'] as String? ?? '',
        rolling: j['rolling'] as bool? ?? false,
        secretHex: j['secretHex'] as String? ?? '',
      );

  static StownConfig get defaults => StownConfig(
        deviceId: StownPacket.generateDeviceId(),
        locks: [
          GateLock(name: 'Подъезд 1', number: '7702'),
          GateLock(name: 'Подъезд 2', number: '7703'),
        ],
      );

  StownConfig copyWith({
    int? command,
    IdentifierMode? identifierMode,
    String? deviceId,
    String? macValue,
    String? uuidValue,
    String? phoneValue,
    String? imeiValue,
    List<GateLock>? locks,
    int? selectedLock,
    WrapperFormat? wrapper,
    int? companyId,
    String? serviceUuid,
    String? tagName,
    bool? rolling,
    String? secretHex,
  }) =>
      StownConfig(
        command: command ?? this.command,
        identifierMode: identifierMode ?? this.identifierMode,
        deviceId: deviceId ?? this.deviceId,
        macValue: macValue ?? this.macValue,
        uuidValue: uuidValue ?? this.uuidValue,
        phoneValue: phoneValue ?? this.phoneValue,
        imeiValue: imeiValue ?? this.imeiValue,
        locks: locks ?? this.locks,
        selectedLock: selectedLock ?? this.selectedLock,
        wrapper: wrapper ?? this.wrapper,
        companyId: companyId ?? this.companyId,
        serviceUuid: serviceUuid ?? this.serviceUuid,
        tagName: tagName ?? this.tagName,
      );
}
