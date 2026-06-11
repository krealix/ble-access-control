import 'dart:typed_data';

import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';

import '../models/stown_packet.dart';

/// Вещание 10-байтного STOWN-пакета через flutter_ble_peripheral.
///
/// Три обёртки:
///   - manufacturer : manufacturerId + 10 байт
///   - service      : serviceUuid + serviceData(10 байт)
///   - ibeacon      : Apple manufacturer data (02 15 + UUID + major + minor + power),
///                    10 байт упакованы в первые 10 байт UUID
class StownAdvertiser {
  StownAdvertiser._();
  static final StownAdvertiser instance = StownAdvertiser._();

  final FlutterBlePeripheral _peripheral = FlutterBlePeripheral();
  bool _advertising = false;
  bool get isAdvertising => _advertising;

  Future<bool> isSupported() => _peripheral.isSupported;

  Future<BluetoothPeripheralState> start(
    Uint8List packet,
    StownConfig config,
  ) async {
    final data = _build(packet, config);
    final state = await _peripheral.start(advertiseData: data);
    _advertising = true;
    return state;
  }

  Future<void> stop() async {
    await _peripheral.stop();
    _advertising = false;
  }

  AdvertiseData _build(Uint8List packet, StownConfig config) {
    switch (config.wrapper) {
      case WrapperFormat.manufacturer:
        return AdvertiseData(
          manufacturerId: config.companyId,
          manufacturerData: packet,
        );

      case WrapperFormat.service:
        final uuid = _serviceUuidFull(config.serviceUuid);
        return AdvertiseData(
          serviceUuid: uuid,
          serviceDataUuid: uuid,
          serviceData: packet,
        );

      case WrapperFormat.ibeacon:
        // Упаковываем 10 байт в iBeacon: первые 10 байт UUID = packet,
        // остаток UUID = 0, major/minor берём из packet (lock в minor).
        final uuidBytes = Uint8List(16);
        for (var i = 0; i < packet.length && i < 16; i++) {
          uuidBytes[i] = packet[i];
        }
        final major = (packet[0] << 8) | packet[1]; // cmd + первый байт id
        final minor = (packet[8] << 8) | packet[9]; // номер замка
        final payload = BytesBuilder()
          ..addByte(0x02)
          ..addByte(0x15)
          ..add(uuidBytes)
          ..addByte((major >> 8) & 0xFF)
          ..addByte(major & 0xFF)
          ..addByte((minor >> 8) & 0xFF)
          ..addByte(minor & 0xFF)
          ..addByte(0xC5); // measured power -59
        return AdvertiseData(
          manufacturerId: 0x004C,
          manufacturerData: payload.toBytes(),
        );
    }
  }

  /// Превращает 16-битный UUID (FFF0) в полный 128-битный Bluetooth Base UUID.
  String _serviceUuidFull(String uuid16) {
    final clean = uuid16.replaceAll('0x', '').replaceAll(' ', '').toUpperCase();
    // Base UUID: 0000XXXX-0000-1000-8000-00805F9B34FB
    return '0000$clean-0000-1000-8000-00805F9B34FB';
  }

  /// Как примерно выглядит в эфире (для UI).
  static String wirePreview(Uint8List packet, StownConfig config) {
    final hexp = StownPacket.format(packet);
    switch (config.wrapper) {
      case WrapperFormat.manufacturer:
        final lo = (config.companyId & 0xFF).toRadixString(16).padLeft(2, '0').toUpperCase();
        final hi = ((config.companyId >> 8) & 0xFF).toRadixString(16).padLeft(2, '0').toUpperCase();
        return 'FF $lo $hi | $hexp';
      case WrapperFormat.service:
        return '16 ${config.serviceUuid} | $hexp';
      case WrapperFormat.ibeacon:
        return 'iBeacon (UUID←пакет, minor←замок)';
    }
  }
}
