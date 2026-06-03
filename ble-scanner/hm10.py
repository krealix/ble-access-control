"""HM10 (HMSoft) BLE → RS-485 мост: подключение и отправка 10-байтного пакета.

HM10 — прозрачный BLE↔UART мост. Чтобы отправить данные в RS-485 (и открыть
замок), нужно НЕ сканировать, а ПОДКЛЮЧИТЬСЯ к модулю и записать байты в
характеристику FFE1 (сервис FFE0). Что записали в FFE1 — вылетает в UART/RS-485.
Ответ замка приходит обратно как notify на FFE1.

Формат пакета (10 байт), как на схеме `87 00 00 00 00 00 00 00 | 77 02`:
    [0]      команда (0x87 или 0x01) — открытие, обычно не меняется
    [1..7]   идентификатор (MAC авторизованного устройства), 7 байт, незанятое = 0x00
    [8..9]   номер замка в HEX, big-endian (напр. 0x7702 -> 77 02)

Модуль:
    - не зависит от UI, переиспользуется и десктопом, и CLI;
    - запускать корутины в отдельном потоке со своим event loop (как в ble_app).

CLI-тест (скан 8 c + отправка на первый найденный HM10):
    python hm10.py
"""
from __future__ import annotations

import asyncio
from typing import Callable, Optional

from bleak import BleakClient, BleakScanner

# Стандартный GATT прозрачного моста HM-10/HM-11 (Jinan Huamao, имя "HMSoft").
FFE0_SERVICE = "0000ffe0-0000-1000-8000-00805f9b34fb"
FFE1_CHAR = "0000ffe1-0000-1000-8000-00805f9b34fb"
DEFAULT_NAME = "HMSoft"

PAYLOAD_LEN = 10
IDENT_LEN = 7  # байты [1..7]


# --------------------------------------------------------------------------- #
# Сборка пакета / парсинг ввода
# --------------------------------------------------------------------------- #


def build_payload(lock_id: int, cmd: int = 0x87, ident: bytes = b"") -> bytes:
    """Собирает 10 байт: [cmd] + [7 байт идентификатора] + [lock_hi, lock_lo].

    lock_id — 0..0xFFFF (номер замка, напр. 0x7702).
    cmd     — 0..0xFF (обычно 0x87 или 0x01).
    ident   — до 7 байт (MAC = 6 байт), хвост добивается нулями.
    """
    if not 0 <= cmd <= 0xFF:
        raise ValueError("Команда должна быть в диапазоне 00..FF")
    if not 0 <= lock_id <= 0xFFFF:
        raise ValueError("Номер замка должен быть в диапазоне 0000..FFFF")
    ident = bytes(ident)[:IDENT_LEN].ljust(IDENT_LEN, b"\x00")
    payload = bytes([cmd]) + ident + bytes([(lock_id >> 8) & 0xFF, lock_id & 0xFF])
    assert len(payload) == PAYLOAD_LEN
    return payload


def parse_ident(s: Optional[str]) -> bytes:
    """'AA:BB:CC:DD:EE:FF' / 'AABBCCDDEEFF' / '' -> bytes (макс. 7 байт)."""
    s = (s or "").strip().replace(":", "").replace("-", "").replace(" ", "")
    if not s:
        return b""
    try:
        b = bytes.fromhex(s)
    except ValueError:
        raise ValueError(
            "Идентификатор: только hex (MAC), напр. AA:BB:CC:DD:EE:FF"
        )
    if len(b) > IDENT_LEN:
        raise ValueError(
            f"Идентификатор: максимум {IDENT_LEN} байт (14 hex). MAC = 6 байт — ок."
        )
    return b


# --------------------------------------------------------------------------- #
# BLE-операции (асинхронные, через bleak)
# --------------------------------------------------------------------------- #


async def scan_hm10(
    timeout: float = 8.0,
    name_contains: Optional[str] = DEFAULT_NAME,
) -> list[tuple[str, str, int]]:
    """Сканирует BLE timeout секунд. Возвращает [(name, address, rssi), ...].

    Совпавшие по имени (HMSoft) идут первыми. Если name_contains=None —
    возвращаются все устройства (на случай, если модуль переименован).
    """
    found: dict[str, tuple[str, str, int]] = {}

    def cb(device, adv) -> None:
        name = adv.local_name or device.name or "—"
        rssi = adv.rssi if adv.rssi is not None else -999
        found[device.address] = (name, device.address, rssi)

    scanner = BleakScanner(detection_callback=cb)
    await scanner.start()
    try:
        await asyncio.sleep(timeout)
    finally:
        await scanner.stop()

    items = list(found.values())
    if name_contains:
        nc = name_contains.lower()
        named = sorted(
            (x for x in items if nc in (x[0] or "").lower()),
            key=lambda x: x[2],
            reverse=True,
        )
        rest = sorted(
            (x for x in items if nc not in (x[0] or "").lower()),
            key=lambda x: x[2],
            reverse=True,
        )
        return named + rest
    return sorted(items, key=lambda x: x[2], reverse=True)


async def send_payload(
    address: str,
    payload: bytes,
    on_log: Optional[Callable[[str], None]] = None,
    settle: float = 1.5,
) -> list[bytes]:
    """Подключается к HM10, пишет payload в FFE1, ждёт ответ. Возвращает ответы.

    address — MAC/адрес HM10.
    payload — ровно 10 байт (см. build_payload).
    on_log  — колбэк для текстового лога (потокобезопасно держать его на
              стороне вызывающего; здесь просто дёргается).
    """

    def log(msg: str) -> None:
        if on_log:
            on_log(msg)

    responses: list[bytes] = []

    def on_notify(_char, data: bytearray) -> None:
        b = bytes(data)
        responses.append(b)
        log("RX: " + b.hex(" ").upper())

    # Обновляем устройство прямо перед подключением: на Windows коннект по
    # «старому» адресу часто отваливается по таймауту. Заодно сразу понятно,
    # отвечает ли вообще кто-то на этом адресе.
    log(f"Ищу {address} в эфире…")
    device = await BleakScanner.find_device_by_address(address, timeout=10)
    if device is None:
        log(
            "Внимание: по этому адресу никто не отвечает "
            "(выключен / далеко / занят телефоном / это не HM10). "
            "Пробую подключиться напрямую…"
        )
    target = device if device is not None else address

    # Пауза: на Windows коннект сразу после скана иногда конфликтует с радио.
    await asyncio.sleep(0.3)

    last_err: Optional[Exception] = None
    for attempt in range(1, 3):  # до 2 попыток: первый коннект на Windows часто срывается
        client = BleakClient(target, timeout=20)
        try:
            log(f"Подключение к {address} (попытка {attempt}/2)…")
            # Жёсткий предел, чтобы коннект не висел вечно (баг WinRT).
            await asyncio.wait_for(client.connect(), timeout=25)
            log("Подключено. Открываю FFE1…")

            # Ответ замка (если FFE1 поддерживает notify — обычно да).
            try:
                await client.start_notify(FFE1_CHAR, on_notify)
            except Exception as e:  # noqa: BLE001
                log(f"notify недоступен ({type(e).__name__}) — ответ замка не увидим")

            log("TX: " + payload.hex(" ").upper())
            # Сначала write-without-response (как любит HM10),
            # при отказе характеристики — обычная запись с подтверждением.
            try:
                await client.write_gatt_char(FFE1_CHAR, payload, response=False)
            except Exception as e1:  # noqa: BLE001
                log(f"write без ответа не прошёл ({type(e1).__name__}); "
                    "пробую с подтверждением…")
                await client.write_gatt_char(FFE1_CHAR, payload, response=True)

            await asyncio.sleep(settle)  # даём замку ответить
            log("Отправлено.")
            return responses
        except asyncio.TimeoutError:
            last_err = TimeoutError(
                "коннект завис (25 c). Останови «Сканер» в приложении, "
                "отключи телефон от модуля и выключи/включи Bluetooth на ПК."
            )
            log(f"Попытка {attempt}: коннект завис (25 c)")
        except Exception as e:  # noqa: BLE001
            last_err = e
            log(f"Попытка {attempt} не удалась: {str(e).strip() or type(e).__name__}")
        finally:
            try:
                await client.disconnect()
            except Exception:  # noqa: BLE001
                pass
        if attempt < 2:
            await asyncio.sleep(1.5)

    assert last_err is not None
    raise last_err


# --------------------------------------------------------------------------- #
# Диагностика и CLI-тест
# --------------------------------------------------------------------------- #


async def probe(address: str, on_log: Optional[Callable[[str], None]] = None) -> None:
    """Только подключиться и показать сервисы/характеристики. Ничего не шлёт."""

    def log(msg: str) -> None:
        if on_log:
            on_log(msg)

    log(f"Ищу {address} в эфире…")
    device = await BleakScanner.find_device_by_address(address, timeout=10)
    if device is None:
        log("По адресу никто не отвечает в эфире (всё равно пробую подключиться).")
    target = device if device is not None else address
    await asyncio.sleep(0.3)

    log(f"Подключение к {address}…")
    client = BleakClient(target, timeout=20)
    await asyncio.wait_for(client.connect(), timeout=25)
    try:
        log("ПОДКЛЮЧЕНО. GATT:")
        has_ffe1 = False
        for service in client.services:
            log(f"  service {service.uuid}")
            for ch in service.characteristics:
                log(f"    char {ch.uuid}  [{','.join(ch.properties)}]")
                if str(ch.uuid).lower() == FFE1_CHAR:
                    has_ffe1 = True
        log(
            "FFE1 на месте — модуль готов принимать байты."
            if has_ffe1
            else "FFE1 не найдена — это другое устройство/прошивка."
        )
    finally:
        await client.disconnect()
    log("Отключено.")


def _print_devices(devices: list[tuple[str, str, int]]) -> None:
    if not devices:
        print("HM10 не найден. Включи модуль и Bluetooth, попробуй снова.")
        return
    print(f"Найдено устройств: {len(devices)}")
    for name, addr, rssi in devices:
        print(f"  {rssi:>5} dBm   {addr}   {name}")


async def _cli(args) -> None:
    # Адрес: явный --mac или первый из скана (скан только если --mac не задан).
    target = args.mac
    if target is None:
        print(f"Скан {args.scan:.0f} c…")
        devices = await scan_hm10(
            timeout=args.scan,
            name_contains=None if args.all else DEFAULT_NAME,
        )
        _print_devices(devices)
        target = devices[0][1] if devices else None

    if args.probe:
        if not target:
            print("\nНет адреса: укажи --mac.")
            return
        print(f"\n— PROBE {target} (подключение без отправки) —")
        await probe(target, on_log=print)
        return

    if args.lock is None:
        print("\n(--lock 7702 — открыть замок; --probe --mac … — проверить коннект)")
        return

    if not target:
        print("\nНечего открывать: HM10 не найден и --mac не задан.")
        return

    ident = parse_ident(args.ident) if args.ident else b""
    payload = build_payload(args.lock, cmd=args.cmd, ident=ident)
    print(f"\nОтправляю {payload.hex(' ').upper()} на {target}")
    await send_payload(target, payload, on_log=print)


def _main() -> None:
    import argparse

    p = argparse.ArgumentParser(
        description="HM10 тест: скан BLE и отправка 10 байт для открытия замка."
    )
    p.add_argument(
        "--lock",
        type=lambda s: int(s, 16),
        help="номер замка в hex, напр. 7702. Без него — только скан.",
    )
    p.add_argument(
        "--cmd",
        type=lambda s: int(s, 16),
        default=0x87,
        help="команда в hex (по умолчанию 87).",
    )
    p.add_argument(
        "--mac",
        help="MAC HM10 (по умолчанию — первый найденный HMSoft).",
    )
    p.add_argument(
        "--ident",
        help="идентификатор в байты 2–8, напр. AA:BB:CC:DD:EE:FF.",
    )
    p.add_argument(
        "--scan", type=float, default=8.0, help="секунды сканирования (8 по умолч.)."
    )
    p.add_argument(
        "--all",
        action="store_true",
        help="показывать все устройства, не только HMSoft.",
    )
    p.add_argument(
        "--probe",
        action="store_true",
        help="только подключиться и показать сервисы (без отправки, не открывает замок).",
    )
    args = p.parse_args()
    try:
        asyncio.run(_cli(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    _main()
