"""Юнит-тесты парсера ble_scanner: подсовываем заведомо корректные/битые
BLE-рекламы и проверяем, что парсер возвращает правильный тип маяка и поля.

Запуск: python _test_scanner.py
"""
from __future__ import annotations

import sys
from datetime import datetime

from bleak.backends.device import BLEDevice
from bleak.backends.scanner import AdvertisementData

from ble_scanner import (
    APPLE_MFR_ID,
    BeaconKind,
    _parse_eddystone,
    _parse_ibeacon,
    parse,
)


def adv(
    *,
    manufacturer_data=None,
    service_data=None,
    service_uuids=None,
    local_name=None,
    tx_power=None,
    rssi=-60,
) -> AdvertisementData:
    return AdvertisementData(
        local_name=local_name,
        manufacturer_data=manufacturer_data or {},
        service_data=service_data or {},
        service_uuids=service_uuids or [],
        tx_power=tx_power,
        rssi=rssi,
        platform_data=(),
    )


def dev(addr: str = "AA:BB:CC:DD:EE:FF", name=None) -> BLEDevice:
    return BLEDevice(addr, name, details=None)


# ---- известные эталонные пакеты ----

IBEACON_PAYLOAD = bytes.fromhex(
    "0215"                                  # subtype + length
    "E2C56DB5DFFB48D2B060D0F5A71096E0"      # UUID (классика Apple "AirLocate")
    "0001"                                  # Major = 1
    "0002"                                  # Minor = 2
    "C5"                                    # TX = -59 dBm (0xC5 = -59 signed)
)

APPLE_NEARBY_INFO = bytes.fromhex("10050C18115B64")  # subtype 0x10 — Continuity, не iBeacon

EDDYSTONE_URL = bytes.fromhex(
    "10"     # frame type = URL
    "EC"     # TX = -20 dBm
    "03"     # scheme = https://
    + "666c75747465722e646576"               # "flutter.dev"
)

EDDYSTONE_UID = bytes.fromhex(
    "00"     # frame type = UID
    "EC"     # TX = -20 dBm
    + "1122334455667788AABB"                # namespace (10B)
    + "AABBCCDDEEFF"                        # instance (6B)
)

EDDYSTONE_TLM = bytes.fromhex(
    "20"     # frame type = TLM
    "00"     # version
    "0BB8"   # battery 3000 mV
    "1A00"   # temperature
    "00000064"
    "00001388"
)


# ---- ассерты ----

passed = 0
failed: list[str] = []


def check(name: str, cond: bool, extra: str = "") -> None:
    global passed
    if cond:
        print(f"  [OK]   {name}")
        passed += 1
    else:
        print(f"  [FAIL] {name}  {extra}")
        failed.append(name)


# ---- тесты ----

print("\n=== _parse_ibeacon (низкоуровневый) ===")
ib = _parse_ibeacon(IBEACON_PAYLOAD)
check("распознаёт валидный iBeacon", ib is not None)
check("UUID отформатирован 8-4-4-4-12", ib and ib["UUID"] == "E2C56DB5-DFFB-48D2-B060-D0F5A71096E0", f"got {ib}")
check("Major распарсен big-endian", ib and ib["Major"] == "1")
check("Minor распарсен big-endian", ib and ib["Minor"] == "2")
check("TX Power signed parse", ib and ib["TX"] == "-59 dBm")

check("отбрасывает короткий пакет",     _parse_ibeacon(b"\x02\x15\x00\x00") is None)
check("отбрасывает неверный subtype",   _parse_ibeacon(b"\x10\x15" + b"\x00" * 21) is None)
check("отбрасывает Apple Continuity",   _parse_ibeacon(APPLE_NEARBY_INFO) is None)
check("отбрасывает пустые байты",       _parse_ibeacon(b"") is None)


print("\n=== _parse_eddystone (низкоуровневый) ===")
eu = _parse_eddystone(EDDYSTONE_URL)
check("распознан Eddystone-URL", eu is not None and eu[0] == BeaconKind.EDDYSTONE_URL)
check("URL раскодирован",        eu and eu[1]["URL"] == "https://flutter.dev", f"got {eu}")

euid = _parse_eddystone(EDDYSTONE_UID)
check("распознан Eddystone-UID", euid is not None and euid[0] == BeaconKind.EDDYSTONE_UID)
check("namespace 10 байт",        euid and euid[1]["Namespace"] == "1122334455667788AABB")
check("instance 6 байт",          euid and euid[1]["Instance"] == "AABBCCDDEEFF")

etlm = _parse_eddystone(EDDYSTONE_TLM)
check("распознан Eddystone-TLM", etlm is not None and etlm[0] == BeaconKind.EDDYSTONE_TLM)

check("Eddystone отбрасывает 1 байт", _parse_eddystone(b"\x00") is None)


print("\n=== parse() — интеграция ===")
b = parse(dev(), adv(manufacturer_data={APPLE_MFR_ID: IBEACON_PAYLOAD}, rssi=-55))
check("iBeacon в manufacturer_data -> IBEACON", b.kind == BeaconKind.IBEACON)
check("RSSI пробрасывается",        b.rssi == -55)
check("Fields содержат UUID",       "UUID" in b.fields)

b = parse(dev(), adv(manufacturer_data={APPLE_MFR_ID: APPLE_NEARBY_INFO}))
check("Apple Continuity -> GENERIC", b.kind == BeaconKind.GENERIC, f"got {b.kind}")

b = parse(dev(), adv(service_data={"0000feaa-0000-1000-8000-00805f9b34fb": EDDYSTONE_URL}))
check("Eddystone-URL по сервису feaa -> EDDYSTONE_URL", b.kind == BeaconKind.EDDYSTONE_URL)
check("URL в полях",                 b.fields.get("URL") == "https://flutter.dev")

b = parse(dev(), adv(service_data={"0000feaa-0000-1000-8000-00805f9b34fb": EDDYSTONE_UID}))
check("Eddystone-UID по сервису feaa -> EDDYSTONE_UID", b.kind == BeaconKind.EDDYSTONE_UID)

b = parse(dev(), adv())
check("Пустая реклама -> GENERIC",   b.kind == BeaconKind.GENERIC)

b = parse(dev(), adv(manufacturer_data={0xFFFF: b"\xDE\xAD\xBE\xEF"}))
check("Чужой Mfr ID -> GENERIC",     b.kind == BeaconKind.GENERIC)
check("Mfr данные попали в fields",  "Mfr" in b.fields and "FFFF" in b.fields["Mfr"])

b = parse(dev(name="MyTag"), adv(local_name=None))
check("Имя берётся из device.name", b.name == "MyTag")

b = parse(dev(name="X"), adv(local_name="Y"))
check("local_name приоритетнее device.name", b.name == "Y")


# ---- AuthorizedVehicle: матчинг по Major/Minor/MAC ----

from ble_gateway import AuthorizedVehicle, normalize_mac

print("\n=== AuthorizedVehicle.matches() ===")

MAC_OWN = "AA:BB:CC:DD:EE:FF"
MAC_OTHER = "11:22:33:44:55:66"

v = AuthorizedVehicle(name="A", major=1)
check("major-only: совпадение",        v.matches(1, 99, MAC_OWN) is True)
check("major-only: чужой major",       v.matches(2, 99, MAC_OWN) is False)
check("major-only: любой Minor ок",    v.matches(1, 12345, MAC_OWN) is True)
check("major-only: любой MAC ок",      v.matches(1, 99, MAC_OTHER) is True)

v = AuthorizedVehicle(name="B", major=1, minor=2)
check("major+minor: совпало",           v.matches(1, 2, MAC_OWN) is True)
check("major+minor: верный major, чужой minor", v.matches(1, 3, MAC_OWN) is False)

v = AuthorizedVehicle(name="C", major=1, minor=2, mac=MAC_OWN)
check("triple: всё совпало",            v.matches(1, 2, MAC_OWN) is True)
check("triple: чужой MAC отбит",        v.matches(1, 2, MAC_OTHER) is False)
check("triple: MAC регистронезависим",  v.matches(1, 2, MAC_OWN.lower()) is True)

v = AuthorizedVehicle(name="D", mac=MAC_OWN)
check("mac-only: совпало",              v.matches(99, 99, MAC_OWN) is True)
check("mac-only: чужой MAC",            v.matches(99, 99, MAC_OTHER) is False)
check("mac-only: пустой MAC",           v.matches(99, 99, "") is False)

v = AuthorizedVehicle(name="E")
check("пустая запись -> не матчит ни на что",
      v.matches(1, 2, MAC_OWN) is False)

print("\n=== normalize_mac ===")
check("AA:BB:CC:DD:EE:FF без изменений",
      normalize_mac("AA:BB:CC:DD:EE:FF") == "AA:BB:CC:DD:EE:FF")
check("lowercase приводится к UPPER",
      normalize_mac("aa:bb:cc:dd:ee:ff") == "AA:BB:CC:DD:EE:FF")
check("разделитель '-' конвертируется в ':'",
      normalize_mac("AA-BB-CC-DD-EE-FF") == "AA:BB:CC:DD:EE:FF")
check("пробелы зачищаются",
      normalize_mac(" AA:BB:CC:DD:EE:FF ") == "AA:BB:CC:DD:EE:FF")
check("слишком короткий -> None",
      normalize_mac("AA:BB:CC") is None)
check("без двоеточий -> None (защита от мусора)",
      normalize_mac("AABBCCDDEEFF") is None)
check("нехекс -> None",
      normalize_mac("ZZ:BB:CC:DD:EE:FF") is None)
check("пустая -> None",                 normalize_mac("") is None)
check("None -> None",                   normalize_mac(None) is None)


# ---- итог ----

print(f"\n=== Итог: {passed} прошло, {len(failed)} упало ===")
if failed:
    for f in failed:
        print(f"  - {f}")
    sys.exit(1)
sys.exit(0)
