import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';

import '../models/stown_packet.dart';
import 'bt_info.dart';

/// Максимальная длина имени метки в эфире. Имя broadcast'ится в том же 31-байтном
/// пакете, что и 10 байт данных, поэтому длинное имя переполняет рекламу
/// (ошибка DATA_TOO_LARGE). Ограничиваем консервативно.
const int kMaxTagNameLen = 12;

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

  /// true, если последний запуск прошёл, но имя пришлось убрать из эфира
  /// (телефон отказался вещать пакет с именем). Метка работает, но без имени.
  bool _nameDropped = false;
  bool get lastNameDropped => _nameDropped;

  /// Имя BT-адаптера до того как мы его подменили (для восстановления на stop).
  String? _originalBtName;

  Future<bool> isSupported() => _peripheral.isSupported;

  Future<BluetoothPeripheralState> start(
    Uint8List packet,
    StownConfig config,
  ) async {
    _nameDropped = false;
    final name = _safeName(config.tagName);
    // Имя метки работает только для manufacturer/service (в iBeacon пакет полон).
    // На Android имя в рекламе = имя BT-адаптера: задаём его перед стартом и
    // восстанавливаем при остановке. Имя короткое, чтобы не переполнить пакет.
    if (name != null && config.wrapper != WrapperFormat.ibeacon) {
      _originalBtName ??= await BtInfo.getBluetoothName();
      await BtInfo.setBluetoothName(name);
      // setName применяется асинхронно — дать имени распространиться.
      await Future.delayed(const Duration(milliseconds: 350));
    }

    try {
      final data = _build(packet, config);
      final state =
          await _peripheral.start(advertiseData: data, advertiseSettings: _legacySettings());
      _advertising = true;
      return state;
    } on PlatformException {
      // Имя (= имя адаптера в эфире) — частый источник отказа вещания на
      // отдельных прошивках. Чтобы метка всё равно вышла в эфир и шлагбаум
      // открывался, повторяем без имени.
      if (name == null || config.wrapper == WrapperFormat.ibeacon) rethrow;
      final data = _build(packet, config, dropName: true);
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
  /// (ext-adv не поддерживается) падает с HCI-кодом 18 (Invalid HCI Command
  /// Parameters). connectable=false — это маяк; timeout=0 — вещать непрерывно.
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
    // Возвращаем исходное имя BT, если меняли.
    if (_originalBtName != null) {
      await BtInfo.setBluetoothName(_originalBtName!);
      _originalBtName = null;
    }
  }

  /// Имя для эфира: обрезаем до безопасной длины; пустое → null.
  String? _safeName(String raw) {
    final n = raw.trim();
    if (n.isEmpty) return null;
    return n.length > kMaxTagNameLen ? n.substring(0, kMaxTagNameLen) : n;
  }

  AdvertiseData _build(Uint8List packet, StownConfig config,
      {bool dropName = false}) {
    // Имя метки влезает только у manufacturer/service — у iBeacon пакет
    // уже заполнен (UUID+Major+Minor). На Android транслируется имя адаптера
    // (мы задали его в start), поэтому includeDeviceName=true.
    // dropName=true — аварийный режим без имени (если телефон отказался вещать).
    final name = dropName ? null : _safeName(config.tagName);
    final hasName = name != null;

    switch (config.wrapper) {
      case WrapperFormat.manufacturer:
        return AdvertiseData(
          manufacturerId: config.companyId,
          manufacturerData: packet,
          localName: name,
          includeDeviceName: hasName,
        );

      case WrapperFormat.service:
        final uuid = _serviceUuidFull(config.serviceUuid);
        return AdvertiseData(
          serviceUuid: uuid,
          serviceDataUuid: uuid,
          serviceData: packet,
          localName: name,
          includeDeviceName: hasName,
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
