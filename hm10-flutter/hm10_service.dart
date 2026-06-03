// HM10 (HMSoft) BLE → RS-485: подключение и отправка 10-байтного пакета.
//
// HM10 — прозрачный BLE↔UART мост. Чтобы открыть замок, надо НЕ слушать
// рекламу, а ПОДКЛЮЧИТЬСЯ к модулю и записать пакет в характеристику FFE1
// (сервис FFE0). Что записали в FFE1 — вылетает в RS-485. Ответ замка
// приходит обратно через notify на FFE1.
//
// Формат пакета (10 байт): [cmd][7 байт идентификатора][lockHi][lockLo]
//   [0]     команда (0x87 / 0x01) — открытие
//   [1..7]  MAC авторизованного устройства, незанятое = 0x00 (UUID 16 байт НЕ влезает)
//   [8..9]  номер замка big-endian (0x7702 -> 77 02)
//
// Зависимость: flutter_blue_plus (см. README.md).

import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// GATT прозрачного моста HM-10/HM-11 (Jinan Huamao, имя "HMSoft").
final Guid kHm10Service = Guid('0000ffe0-0000-1000-8000-00805f9b34fb');
final Guid kHm10Char = Guid('0000ffe1-0000-1000-8000-00805f9b34fb');

const int kPayloadLen = 10;
const int kIdentLen = 7;

/// Собирает 10 байт: [cmd] + [7 байт идентификатора] + [lockHi, lockLo].
List<int> buildPayload(int lockId, {int cmd = 0x87, List<int>? ident}) {
  if (cmd < 0 || cmd > 0xFF) {
    throw ArgumentError('Команда должна быть 00..FF');
  }
  if (lockId < 0 || lockId > 0xFFFF) {
    throw ArgumentError('Номер замка должен быть 0000..FFFF');
  }
  final id = List<int>.filled(kIdentLen, 0);
  if (ident != null) {
    for (var i = 0; i < ident.length && i < kIdentLen; i++) {
      id[i] = ident[i] & 0xFF;
    }
  }
  return [cmd & 0xFF, ...id, (lockId >> 8) & 0xFF, lockId & 0xFF];
}

/// 'AA:BB:CC:DD:EE:FF' / 'AABBCCDDEEFF' / '' -> список байт (макс. 7).
List<int> parseIdent(String s) {
  final clean = s.replaceAll(RegExp(r'[:\-\s]'), '');
  if (clean.isEmpty) return const [];
  if (clean.length % 2 != 0) {
    throw const FormatException('Идентификатор: нечётное число hex-символов');
  }
  final out = <int>[];
  for (var i = 0; i < clean.length; i += 2) {
    final byte = int.tryParse(clean.substring(i, i + 2), radix: 16);
    if (byte == null) {
      throw const FormatException('Идентификатор: только hex (MAC)');
    }
    out.add(byte);
  }
  if (out.length > kIdentLen) {
    throw const FormatException('Идентификатор: максимум 7 байт (MAC = 6 — ок)');
  }
  return out;
}

String hexString(List<int> bytes) => bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join(' ')
    .toUpperCase();

/// Обёртка над одним подключением к HM10.
class Hm10Service {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _char;
  StreamSubscription<List<int>>? _notifySub;

  final _responses = StreamController<List<int>>.broadcast();

  /// Ответы замка (notify с FFE1).
  Stream<List<int>> get responses => _responses.stream;

  bool get isConnected => _device?.isConnected ?? false;

  /// Скан [timeout] секунд. Возвращает найденные HM10, отсортированные по RSSI.
  /// [onlyHmSoft]=false — вернуть все устройства (если модуль переименован).
  static Future<List<ScanResult>> scan({
    Duration timeout = const Duration(seconds: 8),
    bool onlyHmSoft = true,
  }) async {
    final results = <DeviceIdentifier, ScanResult>{};
    final sub = FlutterBluePlus.scanResults.listen((batch) {
      for (final r in batch) {
        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : r.device.platformName;
        if (!onlyHmSoft || name.toLowerCase().contains('hmsoft')) {
          results[r.device.remoteId] = r;
        }
      }
    });
    try {
      await FlutterBluePlus.startScan(timeout: timeout);
      await FlutterBluePlus.isScanning.where((scanning) => !scanning).first;
    } finally {
      await sub.cancel();
      await FlutterBluePlus.stopScan();
    }
    final list = results.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    return list;
  }

  /// Подключиться, найти FFE0/FFE1, включить notify.
  Future<void> connect(BluetoothDevice device) async {
    _device = device;
    await device.connect(timeout: const Duration(seconds: 15));
    final services = await device.discoverServices();

    final svc = services.firstWhere(
      (s) => s.uuid == kHm10Service,
      orElse: () => throw StateError('Сервис FFE0 не найден — это точно HM10?'),
    );
    _char = svc.characteristics.firstWhere(
      (c) => c.uuid == kHm10Char,
      orElse: () => throw StateError('Характеристика FFE1 не найдена'),
    );

    if (_char!.properties.notify || _char!.properties.indicate) {
      await _char!.setNotifyValue(true);
      _notifySub = _char!.onValueReceived.listen(_responses.add);
    }
  }

  /// Отправить готовый пакет (10 байт) в FFE1.
  Future<void> sendPayload(List<int> payload) async {
    final ch = _char;
    if (ch == null) {
      throw StateError('Нет подключения — сначала вызови connect()');
    }
    // HM10 любит write-without-response; если не поддерживается — с ответом.
    final noResp = ch.properties.writeWithoutResponse;
    await ch.write(payload, withoutResponse: noResp);
  }

  /// Шорткат: открыть замок [lockId].
  Future<void> openLock(int lockId, {int cmd = 0x87, List<int>? ident}) {
    return sendPayload(buildPayload(lockId, cmd: cmd, ident: ident));
  }

  Future<void> disconnect() async {
    await _notifySub?.cancel();
    _notifySub = null;
    final d = _device;
    _char = null;
    _device = null;
    await d?.disconnect();
  }

  void dispose() {
    _responses.close();
  }
}

/// Полный цикл одним вызовом: connect → open → подождать ответ → disconnect.
/// Возвращает байты ответа замка (пусто, если notify не пришёл).
Future<List<int>> openLockOnce(
  BluetoothDevice device,
  int lockId, {
  int cmd = 0x87,
  List<int>? ident,
  Duration settle = const Duration(milliseconds: 1500),
}) async {
  final svc = Hm10Service();
  final responses = <int>[];
  final sub = svc.responses.listen(responses.addAll);
  try {
    await svc.connect(device);
    await svc.openLock(lockId, cmd: cmd, ident: ident);
    await Future.delayed(settle);
    return responses;
  } finally {
    await sub.cancel();
    await svc.disconnect();
    svc.dispose();
  }
}
