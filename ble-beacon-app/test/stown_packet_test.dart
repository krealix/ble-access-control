import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ble_beacon_app/models/stown_packet.dart';

void main() {
  test('build device_id packet matches schema', () {
    final ident = StownPacket.buildIdentifier(
        IdentifierMode.deviceId, '11223344556677');
    final pkt = StownPacket.build(
        command: kCmdOpen87, identifier: ident, lockNumber: 0x7702);
    expect(StownPacket.format(pkt), '87 11 22 33 44 55 66 77 77 02');
  });

  test('MAC packet pads to 7 bytes', () {
    final ident =
        StownPacket.buildIdentifier(IdentifierMode.mac, 'AA:BB:CC:DD:EE:FF');
    final pkt = StownPacket.build(
        command: kCmdOpen87, identifier: ident, lockNumber: 0x7703);
    expect(StownPacket.format(pkt), '87 AA BB CC DD EE FF 00 77 03');
  });

  test('decode round-trip', () {
    final ident = StownPacket.buildIdentifier(
        IdentifierMode.deviceId, '11223344556677');
    final pkt = StownPacket.build(
        command: kCmdOpen87, identifier: ident, lockNumber: 0x7702);
    expect(StownPacket.looksLikeStown(pkt), true);
    final dp = StownPacket.decode(pkt)!;
    expect(dp.commandHex, '0x87');
    expect(dp.identifierHex, '11223344556677');
    expect(dp.lockHex, '0x7702');
  });

  test('parseLockNumber hex', () {
    expect(StownPacket.parseLockNumber('7702'), 0x7702);
    expect(StownPacket.parseLockNumber('0x7703'), 0x7703);
  });

  test('non-stown data rejected', () {
    expect(StownPacket.looksLikeStown([0x10, 0x20, 0x30]), false);
    expect(StownPacket.looksLikeStown(Uint8List(10)), false); // cmd=0x00
  });

  test('phone number encodes to 7 bytes and round-trips', () {
    final ident = StownPacket.buildIdentifier(IdentifierMode.phone, '79022717737');
    expect(ident.length, 7);
    // обратное преобразование возвращает тот же номер (без ведущих нулей)
    expect(StownPacket.identifierToPhone(ident), '79022717737');
    // с разделителями — тот же результат (берутся только цифры)
    final ident2 =
        StownPacket.buildIdentifier(IdentifierMode.phone, '+7 (902) 271-77-37');
    expect(ident2, ident);
  });

  test('phone too long is rejected', () {
    expect(
      () => StownPacket.buildIdentifier(IdentifierMode.phone, '9' * 18),
      throwsFormatException,
    );
  });
}
