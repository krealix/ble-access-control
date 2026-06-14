import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Отправка байт на HM-10 по GATT: подключение → discoverServices →
/// запись в характеристику FFE1 (write / write-without-response).
///
/// Совпадает с логикой из STOWN ble.txt: connect, discoverServices,
/// найти write-характеристику, writeCharacteristic.
class Hm10Sender {
  Hm10Sender._();
  static final Hm10Sender instance = Hm10Sender._();

  /// Стандартный HM-10 UART: service FFE0 / char FFE1.
  static final Guid hm10Service = Guid('0000ffe0-0000-1000-8000-00805f9b34fb');
  static final Guid hm10Char = Guid('0000ffe1-0000-1000-8000-00805f9b34fb');

  /// Имена под которыми обычно вещает HM-10 (для подсветки в скане).
  static const nameHints = ['hmsoft', 'hm-10', 'hm10', 'bt05', 'mlt-bt05', 'jdy'];

  // --- Постоянное подключение (для шлюза) ---
  BluetoothDevice? _persistentDevice;
  BluetoothCharacteristic? _persistentChar;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  /// Состояние постоянного подключения для индикатора в UI.
  final ValueNotifier<bool> connected = ValueNotifier<bool>(false);

  bool get persistentConnected =>
      _persistentChar != null && (_persistentDevice?.isConnected ?? false);

  /// Устанавливает (или восстанавливает) постоянное подключение к [mac]
  /// и кэширует write-характеристику. Совместимо с активным сканированием.
  Future<void> ensureConnected(String mac, {void Function(String)? onLog}) async {
    final id = mac.trim().toUpperCase();
    if (persistentConnected && _persistentDevice!.remoteId.str == id) return;
    await disconnectPersistent();

    final device = BluetoothDevice.fromId(id);
    onLog?.call('Подключение к $id…');
    await device.connect(timeout: const Duration(seconds: 15));

    final services = await device.discoverServices();
    BluetoothCharacteristic? target;
    BluetoothCharacteristic? fallback;
    for (final s in services) {
      for (final c in s.characteristics) {
        if (c.uuid == hm10Char) target = c;
        if ((c.properties.write || c.properties.writeWithoutResponse) &&
            fallback == null) {
          fallback = c;
        }
      }
    }
    target ??= fallback;
    if (target == null) {
      try {
        await device.disconnect();
      } catch (_) {}
      throw Hm10Exception('Не найдена характеристика для записи (write)');
    }

    _persistentDevice = device;
    _persistentChar = target;
    connected.value = true;
    _connSub = device.connectionState.listen((st) {
      if (st == BluetoothConnectionState.disconnected) {
        _persistentChar = null;
        connected.value = false;
      }
    });
    onLog?.call('Подключено (постоянно)');
  }

  /// Пишет пакет в постоянное подключение; при обрыве — один реконнект.
  Future<void> writePersistent(String mac, Uint8List packet,
      {void Function(String)? onLog}) async {
    if (!persistentConnected) {
      await ensureConnected(mac, onLog: onLog);
    }
    final c = _persistentChar!;
    await c.write(packet, withoutResponse: c.properties.writeWithoutResponse);
    onLog?.call('Отправлено: ${_fmt(packet)}');
  }

  Future<void> disconnectPersistent() async {
    await _connSub?.cancel();
    _connSub = null;
    _persistentChar = null;
    connected.value = false;
    final d = _persistentDevice;
    _persistentDevice = null;
    if (d != null) {
      try {
        await d.disconnect();
      } catch (_) {}
    }
  }

  /// Сканирование: возвращает поток результатов (отфильтровать/показать в UI).
  Stream<List<ScanResult>> get scanResults => FlutterBluePlus.scanResults;

  Future<void> startScan({Duration timeout = const Duration(seconds: 8)}) async {
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      await FlutterBluePlus.turnOn();
    }
    await FlutterBluePlus.startScan(timeout: timeout);
  }

  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  /// Эвристика: похоже ли устройство на HM-10.
  static bool looksLikeHm10(ScanResult r) {
    final name = (r.advertisementData.advName).toLowerCase();
    final byName = nameHints.any((h) => name.contains(h));
    final byService = r.advertisementData.serviceUuids
        .any((g) => g == hm10Service);
    return byName || byService;
  }

  /// Подключается, пишет [packet] в FFE1 (или первую write-характеристику),
  /// отключается. Бросает [Hm10Exception] при проблемах.
  ///
  /// [onLog] — колбэк для журнала шагов (опционально).
  Future<void> sendPacket(
    BluetoothDevice device,
    Uint8List packet, {
    void Function(String message)? onLog,
    Duration connectTimeout = const Duration(seconds: 15),
  }) async {
    void log(String m) => onLog?.call(m);

    try {
      log('Подключение к ${device.platformName.isEmpty ? device.remoteId.str : device.platformName}...');
      await device.connect(timeout: connectTimeout);
      log('Подключено');
    } catch (e) {
      throw Hm10Exception('Не удалось подключиться: $e');
    }

    try {
      log('Поиск сервисов...');
      final services = await device.discoverServices();
      log('Найдено сервисов: ${services.length}');

      BluetoothCharacteristic? target;
      BluetoothCharacteristic? fallbackWrite;

      for (final s in services) {
        for (final c in s.characteristics) {
          if (c.uuid == hm10Char) {
            target = c;
          }
          if ((c.properties.write || c.properties.writeWithoutResponse) &&
              fallbackWrite == null) {
            fallbackWrite = c;
          }
        }
      }

      target ??= fallbackWrite;
      if (target == null) {
        throw Hm10Exception('Не найдена характеристика для записи (write)');
      }

      final withoutResponse = target.properties.writeWithoutResponse;
      log('Запись ${packet.length} байт в ${target.uuid.str} '
          '(without_response=$withoutResponse)');
      await target.write(packet, withoutResponse: withoutResponse);
      log('Отправлено: ${_fmt(packet)}');
    } on Hm10Exception {
      rethrow;
    } catch (e) {
      throw Hm10Exception('Ошибка записи: $e');
    } finally {
      try {
        await device.disconnect();
        log('Отключено');
      } catch (_) {}
    }
  }

  /// Подключается один раз, пишет несколько пакетов с паузой [gap] между ними,
  /// отключается. Используется шлюзом для последовательности команд 0x01→0x87.
  Future<void> sendPackets(
    BluetoothDevice device,
    List<Uint8List> packets, {
    Duration gap = const Duration(milliseconds: 500),
    void Function(String message)? onLog,
    Duration connectTimeout = const Duration(seconds: 15),
  }) async {
    void log(String m) => onLog?.call(m);

    try {
      log('Подключение...');
      await device.connect(timeout: connectTimeout);
      log('Подключено');
    } catch (e) {
      throw Hm10Exception('Не удалось подключиться: $e');
    }

    try {
      final services = await device.discoverServices();
      BluetoothCharacteristic? target;
      BluetoothCharacteristic? fallbackWrite;
      for (final s in services) {
        for (final c in s.characteristics) {
          if (c.uuid == hm10Char) target = c;
          if ((c.properties.write || c.properties.writeWithoutResponse) &&
              fallbackWrite == null) {
            fallbackWrite = c;
          }
        }
      }
      target ??= fallbackWrite;
      if (target == null) {
        throw Hm10Exception('Не найдена характеристика для записи (write)');
      }
      final withoutResponse = target.properties.writeWithoutResponse;

      for (var i = 0; i < packets.length; i++) {
        if (i > 0) await Future.delayed(gap);
        await target.write(packets[i], withoutResponse: withoutResponse);
        log('Отправлено: ${_fmt(packets[i])}');
      }
    } on Hm10Exception {
      rethrow;
    } catch (e) {
      throw Hm10Exception('Ошибка записи: $e');
    } finally {
      try {
        await device.disconnect();
        log('Отключено');
      } catch (_) {}
    }
  }

  static String _fmt(Uint8List p) =>
      p.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
}

class Hm10Exception implements Exception {
  Hm10Exception(this.message);
  final String message;
  @override
  String toString() => message;
}
