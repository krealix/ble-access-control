import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/beacon.dart';
import '../models/stown_packet.dart';

const _appleMfrId = 0x004C;
const _eddystoneShort = 'feaa';

/// Парсит BLE-объявление в [ParsedBeacon].
ParsedBeacon parseAdvertisement(ScanResult r) {
  final adv = r.advertisementData;
  final id = r.device.remoteId.str;
  final name = adv.advName.isEmpty ? null : adv.advName;
  final now = DateTime.now();

  // iBeacon: manufacturer data with Apple ID, prefix 0x02 0x15
  final apple = adv.manufacturerData[_appleMfrId];
  if (apple != null &&
      apple.length >= 23 &&
      apple[0] == 0x02 &&
      apple[1] == 0x15) {
    final uuidHex = HexUtils.bytesToHex(apple.sublist(2, 18));
    final major = (apple[18] << 8) | apple[19];
    final minor = (apple[20] << 8) | apple[21];
    final tx = apple[22] > 127 ? apple[22] - 256 : apple[22];
    return ParsedBeacon(
      kind: BeaconKind.iBeacon,
      deviceId: id,
      name: name,
      rssi: r.rssi,
      seenAt: now,
      fields: {
        'UUID': HexUtils.formatUuidWithDashes(uuidHex).toUpperCase(),
        'Major': major.toString(),
        'Minor': minor.toString(),
        'TX Power': '$tx dBm',
      },
    );
  }

  // Eddystone: service data with UUID 0xFEAA
  for (final entry in adv.serviceData.entries) {
    final uuid = entry.key.str.toLowerCase();
    if (uuid == _eddystoneShort || uuid.startsWith('0000feaa-')) {
      final data = entry.value;
      if (data.isEmpty) continue;
      final frameType = data[0];
      final tx = data.length > 1
          ? (data[1] > 127 ? data[1] - 256 : data[1])
          : 0;

      if (frameType == 0x00 && data.length >= 18) {
        return ParsedBeacon(
          kind: BeaconKind.eddystoneUid,
          deviceId: id,
          name: name,
          rssi: r.rssi,
          seenAt: now,
          fields: {
            'Namespace': HexUtils.bytesToHex(data.sublist(2, 12)),
            'Instance': HexUtils.bytesToHex(data.sublist(12, 18)),
            'TX Power': '$tx dBm',
          },
        );
      }
      if (frameType == 0x10 && data.length >= 3) {
        const schemes = [
          'http://www.',
          'https://www.',
          'http://',
          'https://'
        ];
        final scheme = data[2];
        final prefix = scheme < schemes.length ? schemes[scheme] : '';
        final body = String.fromCharCodes(data.sublist(3));
        return ParsedBeacon(
          kind: BeaconKind.eddystoneUrl,
          deviceId: id,
          name: name,
          rssi: r.rssi,
          seenAt: now,
          fields: {
            'URL': '$prefix$body',
            'TX Power': '$tx dBm',
          },
        );
      }
      if (frameType == 0x20) {
        return ParsedBeacon(
          kind: BeaconKind.eddystoneTlm,
          deviceId: id,
          name: name,
          rssi: r.rssi,
          seenAt: now,
          fields: {
            'Raw': HexUtils.bytesToHex(data),
          },
        );
      }
    }
  }

  // STOWN 10-байтный пакет — в manufacturer data (не Apple) или service data.
  final stownFields = _parseStown(adv);
  if (stownFields != null) {
    return ParsedBeacon(
      kind: BeaconKind.stown,
      deviceId: id,
      name: name,
      rssi: r.rssi,
      seenAt: now,
      fields: stownFields,
    );
  }

  // Generic / unknown
  final fields = <String, String>{};
  if (adv.serviceUuids.isNotEmpty) {
    fields['Services'] =
        adv.serviceUuids.take(2).map((g) => g.str.toUpperCase()).join(', ');
  }
  if (adv.manufacturerData.isNotEmpty) {
    final entry = adv.manufacturerData.entries.first;
    final hex = HexUtils.bytesToHex(entry.value);
    fields['Mfr'] =
        '0x${entry.key.toRadixString(16).padLeft(4, '0').toUpperCase()}=${hex.length > 32 ? '${hex.substring(0, 32)}...' : hex}';
  }
  if (adv.txPowerLevel != null) {
    fields['TX Power'] = '${adv.txPowerLevel} dBm';
  }
  return ParsedBeacon(
    kind: BeaconKind.generic,
    deviceId: id,
    name: name,
    rssi: r.rssi,
    seenAt: now,
    fields: fields,
  );
}

/// Ищет 10-байтный STOWN-пакет в manufacturer/service data.
Map<String, String>? _parseStown(AdvertisementData adv) {
  final candidates = <List<int>>[];
  for (final entry in adv.manufacturerData.entries) {
    if (entry.key == _appleMfrId) continue; // там iBeacon
    candidates.add(entry.value);
  }
  for (final entry in adv.serviceData.entries) {
    candidates.add(entry.value);
  }
  for (final data in candidates) {
    if (StownPacket.looksLikeStown(data)) {
      final dp = StownPacket.decode(data);
      if (dp != null) {
        return {
          'Cmd': dp.commandHex,
          'ID': dp.identifierHex,
          'Замок': dp.lockHex,
        };
      }
    }
  }
  return null;
}
