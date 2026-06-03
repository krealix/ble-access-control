"""BLE Beacon Generator for Windows 11.

Поддерживаемые форматы:
    - Eddystone-URL
    - Eddystone-UID
    - Custom (свой Manufacturer ID + произвольные данные)

iBeacon на Windows напрямую вещать не получится — Apple Manufacturer ID
(0x004C) системой не пропускается. Используйте телефон/ESP32 для iBeacon.

Использование:
    python ble_generator.py                                # интерактивное меню
    python ble_generator.py eddy-url https://flutter.dev
    python ble_generator.py eddy-uid 11223344556677889900 AABBCCDDEEFF
    python ble_generator.py custom --company-id 0xFFFF --data DEADBEEF
    python ble_generator.py random eddy-url

Установка зависимостей:
    pip install -r requirements.txt

Выход во время вещания — Ctrl+C.
"""
from __future__ import annotations

import argparse
import asyncio
import secrets
import sys
from typing import Optional

from rich.console import Console
from rich.live import Live
from rich.panel import Panel
from rich.table import Table

try:
    from winrt.windows.devices.bluetooth.advertisement import (
        BluetoothLEAdvertisement,
        BluetoothLEAdvertisementDataSection,
        BluetoothLEAdvertisementPublisher,
        BluetoothLEAdvertisementPublisherStatus,
        BluetoothLEManufacturerData,
    )
    from winrt.windows.storage.streams import DataWriter
except ImportError:
    print(
        "Не найдены WinRT-биндинги. Установите зависимости:\n"
        "    pip install -r requirements.txt",
        file=sys.stderr,
    )
    sys.exit(1)


# ---------- payload builders ----------

def _data_section(data_type: int, payload: bytes) -> BluetoothLEAdvertisementDataSection:
    """Создаёт BLE AD-структуру с заданным AD type и сырыми байтами."""
    writer = DataWriter()
    writer.write_bytes(payload)
    section = BluetoothLEAdvertisementDataSection()
    section.data_type = data_type
    section.data = writer.detach_buffer()
    return section


def _strip_url_scheme(url: str) -> tuple[int, str]:
    """Кодирует схему URL по Eddystone-URL спецификации."""
    if url.startswith("http://www."):
        return (0x00, url[11:])
    if url.startswith("https://www."):
        return (0x01, url[12:])
    if url.startswith("http://"):
        return (0x02, url[7:])
    if url.startswith("https://"):
        return (0x03, url[8:])
    # без схемы — считаем как https://
    return (0x03, url)


def build_eddystone_url(url: str, tx_power: int = -20) -> BluetoothLEAdvertisement:
    """Eddystone-URL frame (frame type 0x10)."""
    scheme, body = _strip_url_scheme(url)
    if not body:
        raise ValueError("URL не может быть пустым")
    if len(body) > 17:
        raise ValueError(
            f"URL слишком длинный: {len(body)} символов (максимум 17 после http(s)://)"
        )
    adv = BluetoothLEAdvertisement()
    # AD type 0x03 = Complete List of 16-bit Service UUIDs
    adv.data_sections.append(_data_section(0x03, b"\xAA\xFE"))
    # AD type 0x16 = Service Data 16-bit UUID
    frame = b"\xAA\xFE" + bytes([0x10, tx_power & 0xFF, scheme]) + body.encode("ascii")
    adv.data_sections.append(_data_section(0x16, frame))
    return adv


def build_eddystone_uid(namespace_hex: str, instance_hex: str, tx_power: int = -20) -> BluetoothLEAdvertisement:
    """Eddystone-UID frame (frame type 0x00)."""
    try:
        ns = bytes.fromhex(namespace_hex.replace(" ", ""))
        inst = bytes.fromhex(instance_hex.replace(" ", ""))
    except ValueError as e:
        raise ValueError(f"Некорректный hex: {e}") from None
    if len(ns) != 10:
        raise ValueError(f"Namespace должен быть 10 байт (20 hex-символов), получено {len(ns)} байт")
    if len(inst) != 6:
        raise ValueError(f"Instance должен быть 6 байт (12 hex-символов), получено {len(inst)} байт")

    adv = BluetoothLEAdvertisement()
    adv.data_sections.append(_data_section(0x03, b"\xAA\xFE"))
    frame = b"\xAA\xFE" + bytes([0x00, tx_power & 0xFF]) + ns + inst + b"\x00\x00"
    adv.data_sections.append(_data_section(0x16, frame))
    return adv


def build_custom(company_id: int, data: bytes) -> BluetoothLEAdvertisement:
    """Произвольная Manufacturer Data структура."""
    if not 0 <= company_id <= 0xFFFF:
        raise ValueError(f"Company ID должен быть в диапазоне 0x0000..0xFFFF, получено 0x{company_id:X}")
    if company_id == 0x004C:
        raise ValueError(
            "Apple Manufacturer ID (0x004C) заблокирован Windows. "
            "Для iBeacon используйте телефон или ESP32."
        )
    if len(data) > 27:
        raise ValueError(f"Слишком много данных: {len(data)} байт (макс ~27)")

    adv = BluetoothLEAdvertisement()
    mfr = BluetoothLEManufacturerData()
    mfr.company_id = company_id
    writer = DataWriter()
    writer.write_bytes(data)
    mfr.data = writer.detach_buffer()
    adv.manufacturer_data.append(mfr)
    return adv


# ---------- runner ----------

def _status_name(status: int) -> str:
    mapping = {
        BluetoothLEAdvertisementPublisherStatus.CREATED: "СОЗДАН",
        BluetoothLEAdvertisementPublisherStatus.WAITING: "ОЖИДАНИЕ",
        BluetoothLEAdvertisementPublisherStatus.STARTED: "ВЕЩАЕТ",
        BluetoothLEAdvertisementPublisherStatus.STOPPING: "ОСТАНОВКА",
        BluetoothLEAdvertisementPublisherStatus.STOPPED: "ОСТАНОВЛЕН",
        BluetoothLEAdvertisementPublisherStatus.ABORTED: "ПРЕРВАН",
    }
    return mapping.get(status, f"НЕИЗВЕСТНО({status})")


def _status_color(status: int) -> str:
    if status == BluetoothLEAdvertisementPublisherStatus.STARTED:
        return "bold green"
    if status == BluetoothLEAdvertisementPublisherStatus.WAITING:
        return "yellow"
    if status == BluetoothLEAdvertisementPublisherStatus.ABORTED:
        return "bold red"
    return "dim"


async def run_until_interrupted(
    publisher: BluetoothLEAdvertisementPublisher,
    kind_label: str,
    fields: dict[str, str],
) -> None:
    """Запускает publisher и держит его до Ctrl+C."""
    console = Console()
    publisher.start()
    elapsed = 0.0
    try:
        with Live(refresh_per_second=2, console=console, screen=False) as live:
            while True:
                table = Table.grid(padding=(0, 2))
                table.add_column(style="bold", width=14)
                table.add_column(style="cyan")
                table.add_row("Тип:", kind_label)
                for key, value in fields.items():
                    table.add_row(f"{key}:", value)
                table.add_row("", "")
                status_str = _status_name(publisher.status)
                table.add_row(
                    "Статус:",
                    f"[{_status_color(publisher.status)}]{status_str}[/]",
                )
                table.add_row("Время:", f"{int(elapsed)} сек")
                live.update(
                    Panel(
                        table,
                        title="[bold green]BLE Beacon Generator[/]",
                        subtitle="[dim]Ctrl+C для остановки[/]",
                        border_style="blue",
                    )
                )
                await asyncio.sleep(0.5)
                elapsed += 0.5
    except (KeyboardInterrupt, asyncio.CancelledError):
        pass
    finally:
        try:
            publisher.stop()
        except Exception:
            pass
        console.print("[bold]Вещание остановлено.[/]")


def _start(adv: BluetoothLEAdvertisement, kind: str, fields: dict[str, str]) -> None:
    publisher = BluetoothLEAdvertisementPublisher(adv)
    try:
        asyncio.run(run_until_interrupted(publisher, kind, fields))
    except KeyboardInterrupt:
        pass


# ---------- CLI subcommands ----------

def cmd_eddy_url(args: argparse.Namespace) -> None:
    try:
        adv = build_eddystone_url(args.url, args.tx_power)
    except ValueError as e:
        print(f"Ошибка: {e}", file=sys.stderr)
        sys.exit(1)
    _start(adv, "Eddystone URL", {
        "URL": args.url,
        "TX Power": f"{args.tx_power} dBm",
    })


def cmd_eddy_uid(args: argparse.Namespace) -> None:
    try:
        adv = build_eddystone_uid(args.namespace, args.instance, args.tx_power)
    except ValueError as e:
        print(f"Ошибка: {e}", file=sys.stderr)
        sys.exit(1)
    _start(adv, "Eddystone UID", {
        "Namespace": args.namespace.upper(),
        "Instance": args.instance.upper(),
        "TX Power": f"{args.tx_power} dBm",
    })


def cmd_custom(args: argparse.Namespace) -> None:
    try:
        company_id = int(args.company_id, 0)
    except ValueError:
        print(f"Ошибка: некорректный company-id: {args.company_id}", file=sys.stderr)
        sys.exit(1)
    try:
        data = bytes.fromhex(args.data.replace(" ", ""))
    except ValueError as e:
        print(f"Ошибка: некорректный hex: {e}", file=sys.stderr)
        sys.exit(1)
    try:
        adv = build_custom(company_id, data)
    except ValueError as e:
        print(f"Ошибка: {e}", file=sys.stderr)
        sys.exit(1)
    _start(adv, "Custom", {
        "Company ID": f"0x{company_id:04X}",
        "Data (hex)": data.hex().upper(),
    })


def cmd_random(args: argparse.Namespace) -> None:
    if args.type == "eddy-url":
        urls = ["https://flutter.dev", "https://anthropic.com", "https://example.com", "https://goo.gl/test"]
        url = secrets.choice(urls)
        args.url = url
        args.tx_power = -20
        cmd_eddy_url(args)
    elif args.type == "eddy-uid":
        args.namespace = secrets.token_hex(10)
        args.instance = secrets.token_hex(6)
        args.tx_power = -20
        cmd_eddy_uid(args)
    elif args.type == "custom":
        args.company_id = "0xFFFF"
        args.data = secrets.token_hex(secrets.choice([4, 6, 8]))
        cmd_custom(args)


# ---------- interactive mode ----------

def interactive() -> None:
    console = Console()
    while True:
        console.print()
        console.print(Panel.fit(
            "[bold]BLE Beacon Generator[/]\n\n"
            "[cyan]1[/]  Eddystone URL\n"
            "[cyan]2[/]  Eddystone UID\n"
            "[cyan]3[/]  Custom (manufacturer data)\n"
            "[cyan]r[/]  Random Eddystone URL\n"
            "[cyan]q[/]  Выход",
            title="Меню",
            border_style="blue",
        ))
        choice = console.input("\nВыбор: ").strip().lower()
        try:
            if choice == "q":
                return
            elif choice == "1":
                url = console.input("URL [https://flutter.dev]: ").strip() or "https://flutter.dev"
                tx_input = console.input("TX Power dBm [-20]: ").strip() or "-20"
                tx = int(tx_input)
                args = argparse.Namespace(url=url, tx_power=tx)
                cmd_eddy_url(args)
            elif choice == "2":
                ns = console.input("Namespace (20 hex) [random]: ").strip()
                inst = console.input("Instance (12 hex) [random]: ").strip()
                tx_input = console.input("TX Power dBm [-20]: ").strip() or "-20"
                args = argparse.Namespace(
                    namespace=ns or secrets.token_hex(10),
                    instance=inst or secrets.token_hex(6),
                    tx_power=int(tx_input),
                )
                cmd_eddy_uid(args)
            elif choice == "3":
                cid = console.input("Company ID [0xFFFF]: ").strip() or "0xFFFF"
                data = console.input("Data (hex) [DEADBEEF]: ").strip() or "DEADBEEF"
                args = argparse.Namespace(company_id=cid, data=data)
                cmd_custom(args)
            elif choice == "r":
                args = argparse.Namespace(type="eddy-url")
                cmd_random(args)
            else:
                console.print(f"[red]Неизвестный выбор: {choice}[/]")
        except KeyboardInterrupt:
            console.print("\n[yellow]Прервано[/]")


# ---------- entrypoint ----------

def main() -> None:
    parser = argparse.ArgumentParser(
        prog="ble_generator",
        description="BLE Beacon Generator для Windows (Eddystone + Custom).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    sub = parser.add_subparsers(dest="cmd")

    p_url = sub.add_parser("eddy-url", help="Eddystone-URL")
    p_url.add_argument("url", help="URL (макс 17 символов после http(s)://)")
    p_url.add_argument("--tx-power", type=int, default=-20, help="Калибровка мощности, dBm (по умолчанию -20)")
    p_url.set_defaults(func=cmd_eddy_url)

    p_uid = sub.add_parser("eddy-uid", help="Eddystone-UID")
    p_uid.add_argument("namespace", help="10 байт hex (20 символов)")
    p_uid.add_argument("instance", help="6 байт hex (12 символов)")
    p_uid.add_argument("--tx-power", type=int, default=-20)
    p_uid.set_defaults(func=cmd_eddy_uid)

    p_custom = sub.add_parser("custom", help="Custom manufacturer data")
    p_custom.add_argument("--company-id", default="0xFFFF", help="Company ID, hex или dec (например 0xFFFF)")
    p_custom.add_argument("--data", default="DEADBEEF", help="Сырые данные в hex")
    p_custom.set_defaults(func=cmd_custom)

    p_random = sub.add_parser("random", help="Случайные параметры")
    p_random.add_argument("type", choices=["eddy-url", "eddy-uid", "custom"])
    p_random.set_defaults(func=cmd_random)

    args = parser.parse_args()
    if not args.cmd:
        interactive()
        return
    args.func(args)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
