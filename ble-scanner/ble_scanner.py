"""BLE Beacon Scanner for Windows 11.

Установка:
    pip install -r requirements.txt

Запуск:
    python ble_scanner.py

Выход: Ctrl+C
"""
from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Optional

from bleak import BleakScanner
from bleak.backends.device import BLEDevice
from bleak.backends.scanner import AdvertisementData
from bleak.exc import BleakError
from rich.console import Console
from rich.live import Live
from rich.table import Table


APPLE_MFR_ID = 0x004C
EDDYSTONE_FRAGMENT = "feaa"
STALE_AFTER_SECONDS = 15


class BeaconKind(str, Enum):
    IBEACON = "iBeacon"
    EDDYSTONE_UID = "Eddy UID"
    EDDYSTONE_URL = "Eddy URL"
    EDDYSTONE_TLM = "Eddy TLM"
    GENERIC = "Generic"


KIND_STYLE = {
    BeaconKind.IBEACON: "bold cyan",
    BeaconKind.EDDYSTONE_UID: "bold green",
    BeaconKind.EDDYSTONE_URL: "bold yellow",
    BeaconKind.EDDYSTONE_TLM: "bold magenta",
    BeaconKind.GENERIC: "dim",
}


@dataclass
class Beacon:
    kind: BeaconKind
    address: str
    name: Optional[str]
    rssi: int
    seen_at: datetime
    fields: dict = field(default_factory=dict)


def _fmt_uuid(b: bytes) -> str:
    h = b.hex().upper()
    return f"{h[0:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}"


def _parse_ibeacon(data: bytes) -> Optional[dict]:
    if len(data) < 23 or data[0] != 0x02 or data[1] != 0x15:
        return None
    return {
        "UUID": _fmt_uuid(data[2:18]),
        "Major": str(int.from_bytes(data[18:20], "big")),
        "Minor": str(int.from_bytes(data[20:22], "big")),
        "TX": f"{int.from_bytes(data[22:23], 'big', signed=True)} dBm",
    }


def _parse_eddystone(data: bytes):
    if len(data) < 2:
        return None
    frame_type = data[0]
    tx = int.from_bytes(data[1:2], "big", signed=True)

    if frame_type == 0x00 and len(data) >= 18:
        return BeaconKind.EDDYSTONE_UID, {
            "Namespace": data[2:12].hex().upper(),
            "Instance": data[12:18].hex().upper(),
            "TX": f"{tx} dBm",
        }
    if frame_type == 0x10 and len(data) >= 3:
        schemes = ["http://www.", "https://www.", "http://", "https://"]
        scheme = data[2]
        prefix = schemes[scheme] if scheme < len(schemes) else ""
        url = prefix + data[3:].decode("ascii", errors="replace")
        return BeaconKind.EDDYSTONE_URL, {"URL": url, "TX": f"{tx} dBm"}
    if frame_type == 0x20:
        return BeaconKind.EDDYSTONE_TLM, {"Raw": data.hex().upper()}
    return None


def parse(device: BLEDevice, adv: AdvertisementData) -> Beacon:
    name = adv.local_name or device.name
    rssi = adv.rssi if adv.rssi is not None else 0
    now = datetime.now()

    apple = adv.manufacturer_data.get(APPLE_MFR_ID)
    if apple is not None:
        ib = _parse_ibeacon(apple)
        if ib is not None:
            return Beacon(BeaconKind.IBEACON, device.address, name, rssi, now, ib)

    for uuid_str, sd in adv.service_data.items():
        if EDDYSTONE_FRAGMENT in uuid_str.lower():
            parsed = _parse_eddystone(sd)
            if parsed is not None:
                kind, fields = parsed
                return Beacon(kind, device.address, name, rssi, now, fields)

    fields: dict = {}
    if adv.service_uuids:
        fields["Services"] = ", ".join(adv.service_uuids[:2])
    for mfr_id, mfr_data in list(adv.manufacturer_data.items())[:1]:
        hex_data = mfr_data.hex().upper()
        if len(hex_data) > 40:
            hex_data = hex_data[:40] + "..."
        fields["Mfr"] = f"0x{mfr_id:04X}={hex_data}"
    if adv.tx_power is not None:
        fields["TX"] = f"{adv.tx_power} dBm"
    return Beacon(BeaconKind.GENERIC, device.address, name, rssi, now, fields)


def _rssi_color(rssi: int) -> str:
    if rssi >= -60:
        return "bold green"
    if rssi >= -80:
        return "yellow"
    return "red"


def build_table(beacons: dict, total_ads: int) -> Table:
    table = Table(
        title=f"BLE Scanner  ·  устройств: {len(beacons)}  ·  пакетов: {total_ads}",
        expand=True,
    )
    table.add_column("Тип", width=10)
    table.add_column("Имя", width=18, overflow="ellipsis")
    table.add_column("Адрес", width=18)
    table.add_column("RSSI", width=6, justify="right")
    table.add_column("Параметры", overflow="fold")

    rows = sorted(beacons.values(), key=lambda b: b.rssi, reverse=True)
    for b in rows:
        details = "   ".join(f"[bold]{k}[/]={v}" for k, v in b.fields.items())
        table.add_row(
            f"[{KIND_STYLE[b.kind]}]{b.kind.value}[/]",
            b.name or "[dim]-[/]",
            b.address,
            f"[{_rssi_color(b.rssi)}]{b.rssi}[/]",
            details or "[dim]-[/]",
        )
    return table


async def main() -> None:
    console = Console()
    beacons: dict = {}
    total_ads = 0

    def callback(device: BLEDevice, adv: AdvertisementData) -> None:
        nonlocal total_ads
        total_ads += 1
        if 0x004C in adv.manufacturer_data:
            print(f"[APPLE] {device.address} {adv.manufacturer_data[0x004C].hex()}")
        beacons[device.address] = parse(device, adv)

    scanner = BleakScanner(callback)
    console.print("[bold green]Запуск сканера...[/]  Ctrl+C для выхода.\n")
    try:
        await scanner.start()
    except BleakError as e:
        msg = str(e).lower()
        if "powered" in msg or "not available" in msg:
            console.print("[bold red]Bluetooth выключен.[/] "
                          "Включите Bluetooth в настройках Windows и запустите скрипт снова.")
        else:
            console.print(f"[bold red]Ошибка запуска сканера:[/] {e}")
        return

    try:
        with Live(
            build_table(beacons, total_ads),
            console=console,
            refresh_per_second=2,
            screen=False,
        ) as live:
            while True:
                await asyncio.sleep(0.5)
                now = datetime.now()
                stale = [
                    addr for addr, b in beacons.items()
                    if (now - b.seen_at).total_seconds() > STALE_AFTER_SECONDS
                ]
                for addr in stale:
                    beacons.pop(addr, None)
                live.update(build_table(beacons, total_ads))
    except (KeyboardInterrupt, asyncio.CancelledError):
        pass
    finally:
        await scanner.stop()
        console.print("\n[bold]Сканер остановлен.[/]")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
