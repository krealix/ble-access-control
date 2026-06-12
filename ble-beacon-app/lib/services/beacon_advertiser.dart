import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';

import '../models/beacon.dart';
import 'bt_info.dart';

/// Bluetooth SIG-assigned Eddystone UUID в полном 128-битном виде.
/// На Android-стороне плагин вызывает `UUID.fromString(...)`, который
/// принимает только полный формат — короткий "FEAA" роняет генератор.
const _eddystoneFullUuid = '0000FEAA-0000-1000-8000-00805F9B34FB';

/// Лимит длины имени в эфире (имя делит 31-байтный пакет с данными).
const int _kMaxAdvName = 12;

class BeaconAdvertiser {
  BeaconAdvertiser._();
  static final BeaconAdvertiser instance = BeaconAdvertiser._();

  final FlutterBlePeripheral _peripheral = FlutterBlePeripheral();
  bool _advertising = false;
  String? _originalBtName;

  /// true, если последний запуск прошёл, но имя пришлось убрать из эфира
  /// (телефон отказался вещать пакет с именем).
  bool _nameDropped = false;
  bool get lastNameDropped => _nameDropped;

  bool get isAdvertising => _advertising;

  Future<bool> isSupported() => _peripheral.isSupported;

  Future<BluetoothPeripheralState> start(BeaconPreset preset) async {
    _nameDropped = false;
    // Имя метки: для iBeacon не влезает в пакет. На Android имя в рекламе —
    // это имя BT-адаптера: задаём перед стартом, восстанавливаем на stop.
    final name = _safeName(preset.advName);
    if (name != null && preset.kind != BeaconKind.iBeacon) {
      _originalBtName ??= await BtInfo.getBluetoothName();
      await BtInfo.setBluetoothName(name);
      await Future.delayed(const Duration(milliseconds: 350));
    }
    try {
      final data = _build(preset);
      final state =
          await _peripheral.start(advertiseData: data, advertiseSettings: _legacySettings());
      _advertising = true;
      return state;
    } on PlatformException {
      // Имя в эфире — частая причина отказа вещания на отдельных прошивках.
      // Повторяем без имени, чтобы метка всё равно вышла в эфир.
      if (name == null || preset.kind == BeaconKind.iBeacon) rethrow;
      final data = _build(preset, dropName: true);
      final state =
          await _peripheral.start(advertiseData: data, advertiseSettings: _legacySettings());
      _advertising = true;
      _nameDropped = true;
      return state;
    }
  }

  /// Настройки вещания: принудительно ЛЕГАСИ-реклама (startAdvertising),
  /// поддерживаемая всеми BLE-чипами (4.0+). По умолчанию плагин включает
  /// extended advertising (advertiseSet=true), которое на чипах без BLE 5.0
  /// падает с HCI-кодом 18 (Invalid HCI Command Parameters). connectable=false
  /// — это маяк; timeout=0 — вещать непрерывно.
  AdvertiseSettings _legacySettings() => AdvertiseSettings(
        advertiseSet: false,
        connectable: false,
        timeout: 0,
        advertiseMode: AdvertiseMode.advertiseModeLowLatency,
        txPowerLevel: AdvertiseTxPower.advertiseTxPowerHigh,
      );

  Future<void> stop() async {
    await _peripheral.stop();
    _advertising = false;
    if (_originalBtName != null) {
      await BtInfo.setBluetoothName(_originalBtName!);
      _originalBtName = null;
    }
  }

  String? _safeName(String raw) {
    final n = raw.trim();
    if (n.isEmpty) return null;
    return n.length > _kMaxAdvName ? n.substring(0, _kMaxAdvName) : n;
  }

  AdvertiseData _build(BeaconPreset p, {bool dropName = false}) {
    final name = dropName ? null : _safeName(p.advName);
    final hasName = name != null;
    switch (p.kind) {
      case BeaconKind.iBeacon:
        _validateIBeacon(p);
        return AdvertiseData(
          manufacturerId: 0x004C,
          manufacturerData: _iBeaconPayload(p),
        );
      case BeaconKind.eddystoneUid:
        _validateEddystoneUid(p);
        return AdvertiseData(
          serviceUuid: _eddystoneFullUuid,
          serviceDataUuid: _eddystoneFullUuid,
          serviceData: _eddystoneUidPayload(p),
          localName: name,
          includeDeviceName: hasName,
        );
      case BeaconKind.eddystoneUrl:
        _validateEddystoneUrl(p);
        return AdvertiseData(
          serviceUuid: _eddystoneFullUuid,
          serviceDataUuid: _eddystoneFullUuid,
          serviceData: _eddystoneUrlPayload(p),
          localName: name,
          includeDeviceName: hasName,
        );
      case BeaconKind.custom:
        _validateCustom(p);
        return AdvertiseData(
          serviceUuid: p.serviceUuid.isEmpty
              ? null
              : _normalizeUuid(p.serviceUuid),
          manufacturerId: 0xFFFF,
          manufacturerData: HexUtils.hexToBytes(p.manufacturerData),
          localName: name,
          includeDeviceName: hasName,
        );
      default:
        throw ArgumentError('Unsupported beacon kind: ${p.kind}');
    }
  }

  /// Преобразует UUID (с дефисами или без) в стандартный формат 8-4-4-4-12.
  String _normalizeUuid(String uuid) {
    final clean = uuid.replaceAll('-', '').toUpperCase();
    if (clean.length != 32) {
      throw ArgumentError('UUID должен содержать 32 hex-символа (вы дали ${clean.length})');
    }
    return '${clean.substring(0, 8)}-${clean.substring(8, 12)}-'
        '${clean.substring(12, 16)}-${clean.substring(16, 20)}-'
        '${clean.substring(20, 32)}';
  }

  void _validateIBeacon(BeaconPreset p) {
    final clean = HexUtils.uuidNoDashes(p.uuid);
    if (clean.length != 32) {
      throw ArgumentError('iBeacon UUID должен быть 16 байт (32 hex-символа)');
    }
    if (p.major < 0 || p.major > 0xFFFF) {
      throw ArgumentError('Major должен быть в диапазоне 0..65535');
    }
    if (p.minor < 0 || p.minor > 0xFFFF) {
      throw ArgumentError('Minor должен быть в диапазоне 0..65535');
    }
  }

  void _validateEddystoneUid(BeaconPreset p) {
    final ns = p.namespace.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
    final inst = p.instance.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
    if (ns.length != 20) {
      throw ArgumentError('Namespace должен быть ровно 10 байт (20 hex-символов)');
    }
    if (inst.length != 12) {
      throw ArgumentError('Instance должен быть ровно 6 байт (12 hex-символов)');
    }
  }

  void _validateEddystoneUrl(BeaconPreset p) {
    if (p.url.trim().isEmpty) {
      throw ArgumentError('URL не может быть пустым');
    }
    // У Eddystone URL максимум 17 байт на тело после schema-байта.
    final body = _stripScheme(p.url).body;
    if (body.length > 17) {
      throw ArgumentError('URL слишком длинный (макс 17 символов после http(s)://). '
          'Сейчас: ${body.length}');
    }
  }

  void _validateCustom(BeaconPreset p) {
    if (p.serviceUuid.isNotEmpty) {
      _normalizeUuid(p.serviceUuid); // выкинет ArgumentError, если не валидно
    }
  }

  Uint8List _iBeaconPayload(BeaconPreset p) {
    final uuidBytes = HexUtils.hexToBytes(HexUtils.uuidNoDashes(p.uuid));
    final b = BytesBuilder()
      ..addByte(0x02)
      ..addByte(0x15)
      ..add(uuidBytes)
      ..addByte((p.major >> 8) & 0xFF)
      ..addByte(p.major & 0xFF)
      ..addByte((p.minor >> 8) & 0xFF)
      ..addByte(p.minor & 0xFF)
      ..addByte(p.txPower & 0xFF);
    return b.toBytes();
  }

  /// Возвращаем именно [Uint8List], а не [List<int>], потому что
  /// нативная Android-часть плагина делает `arguments["serviceData"] as ByteArray?`.
  /// Стандартный кодек Flutter преобразует [Uint8List] в `byte[]`,
  /// а обычный [List<int>] — в `ArrayList<Integer>`, что роняет cast.
  Uint8List _eddystoneUidPayload(BeaconPreset p) {
    final ns = HexUtils.hexToBytes(
        p.namespace.padRight(20, '0').substring(0, 20));
    final inst = HexUtils.hexToBytes(
        p.instance.padRight(12, '0').substring(0, 12));
    return Uint8List.fromList([
      0x00,
      p.txPower & 0xFF,
      ...ns,
      ...inst,
      0x00,
      0x00,
    ]);
  }

  Uint8List _eddystoneUrlPayload(BeaconPreset p) {
    final stripped = _stripScheme(p.url);
    return Uint8List.fromList([
      0x10,
      p.txPower & 0xFF,
      stripped.scheme,
      ...stripped.body.codeUnits,
    ]);
  }

  _StrippedUrl _stripScheme(String url) {
    if (url.startsWith('http://www.')) {
      return _StrippedUrl(0x00, url.substring(11));
    }
    if (url.startsWith('https://www.')) {
      return _StrippedUrl(0x01, url.substring(12));
    }
    if (url.startsWith('http://')) {
      return _StrippedUrl(0x02, url.substring(7));
    }
    if (url.startsWith('https://')) {
      return _StrippedUrl(0x03, url.substring(8));
    }
    return _StrippedUrl(0x03, url);
  }
}

class _StrippedUrl {
  _StrippedUrl(this.scheme, this.body);
  final int scheme;
  final String body;
}
