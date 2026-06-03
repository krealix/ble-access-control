"""Диагностический прогон: 20 секунд BLE-скана, агрегируем по адресам и
печатаем сводку. Особое внимание — Apple Manufacturer ID 0x004C и iBeacon-префикс 02 15.
"""
from __future__ import annotations

import asyncio
from collections import defaultdict

from bleak import BleakScanner
from bleak.backends.device import BLEDevice
from bleak.backends.scanner import AdvertisementData


SCAN_SECONDS = 20
APPLE = 0x004C


async def main() -> None:
    per_device: dict[str, dict] = defaultdict(
        lambda: {"name": None, "rssi": -999, "mfr_ids": set(), "apple_raw": None, "services": set(), "service_data": set(), "hits": 0}
    )

    def cb(device: BLEDevice, adv: AdvertisementData) -> None:
        entry = per_device[device.address]
        entry["hits"] += 1
        entry["name"] = adv.local_name or device.name or entry["name"]
        if adv.rssi is not None and adv.rssi > entry["rssi"]:
            entry["rssi"] = adv.rssi
        for mid, mdata in adv.manufacturer_data.items():
            entry["mfr_ids"].add(mid)
            if mid == APPLE:
                entry["apple_raw"] = mdata.hex().upper()
        for u in adv.service_uuids or []:
            entry["services"].add(u.lower())
        for u in (adv.service_data or {}).keys():
            entry["service_data"].add(u.lower())

    scanner = BleakScanner(cb)
    print(f"Старт скана на {SCAN_SECONDS} сек...")
    await scanner.start()
    await asyncio.sleep(SCAN_SECONDS)
    await scanner.stop()

    print(f"\nИтого устройств: {len(per_device)}\n")

    apple_devs = [(a, e) for a, e in per_device.items() if APPLE in e["mfr_ids"]]
    ibeacon_devs = [
        (a, e) for a, e in apple_devs
        if e["apple_raw"] and e["apple_raw"].startswith("0215") and len(e["apple_raw"]) >= 46
    ]
    eddy_devs = [
        (a, e) for a, e in per_device.items()
        if any("feaa" in u for u in e["service_data"])
    ]

    print(f"С Apple MFR (0x004C): {len(apple_devs)}")
    print(f"  из них iBeacon (префикс 02 15): {len(ibeacon_devs)}")
    print(f"С Eddystone service data (feaa): {len(eddy_devs)}\n")

    if apple_devs:
        print("--- Apple-устройства (первые 10) ---")
        for addr, e in apple_devs[:10]:
            raw = e["apple_raw"] or ""
            tag = "iBEACON" if raw.startswith("0215") and len(raw) >= 46 else f"Apple-other (subtype 0x{raw[:2] or '??'})"
            print(f"  {addr}  hits={e['hits']:3d}  rssi={e['rssi']:4d}  name={e['name']!r:20s}  {tag}")
            print(f"     raw = {raw}")
    else:
        print("Apple-устройств не обнаружено.")

    if ibeacon_devs:
        print("\n--- Распарсенные iBeacon ---")
        for addr, e in ibeacon_devs:
            raw = e["apple_raw"]
            uuid_h = raw[4:36]
            uuid = f"{uuid_h[0:8]}-{uuid_h[8:12]}-{uuid_h[12:16]}-{uuid_h[16:20]}-{uuid_h[20:32]}"
            major = int(raw[36:40], 16)
            minor = int(raw[40:44], 16)
            tx = int.from_bytes(bytes.fromhex(raw[44:46]), "big", signed=True)
            print(f"  {addr}  UUID={uuid}  Major={major}  Minor={minor}  TX={tx} dBm  rssi={e['rssi']}")


if __name__ == "__main__":
    asyncio.run(main())
