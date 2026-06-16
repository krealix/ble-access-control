"""Тестовый TCP-приёмник 10-байтных пакетов шлюза.

Имитирует контроллер шлагбаума: слушает TCP-порт и печатает каждый
полученный 10-байтный пакет в hex, разбирая поля:
    cmd (1 байт) · идентификатор (7 байт) · номер замка (2 байта, BE)
Если идентификатор похож на BCD (только цифры 0-9 в полубайтах),
дополнительно печатает раскодированный номер телефона.

Зачем: проверить «Доступ по звонку» и транспорт TCP без реального железа.
В приложении → «Шлюз» поставьте транспорт TCP, хост = IP этого ПК, порт = 9999.

Запуск:
    python tcp_listener.py            # порт 9999
    python tcp_listener.py 9000       # другой порт
"""
from __future__ import annotations

import socket
import sys
from datetime import datetime


def _bcd_to_digits(ident: bytes) -> str | None:
    """7 байт BCD → 14 цифр (или None, если есть не-цифровые полубайты)."""
    out = []
    for b in ident:
        hi, lo = b >> 4, b & 0x0F
        if hi > 9 or lo > 9:
            return None
        out.append(str(hi))
        out.append(str(lo))
    digits = "".join(out).lstrip("0")
    return digits or "0"


def _describe(data: bytes) -> str:
    hexs = " ".join(f"{b:02X}" for b in data)
    if len(data) != 10:
        return f"  raw[{len(data)}]: {hexs}"
    cmd = data[0]
    ident = data[1:8]
    lock = (data[8] << 8) | data[9]
    ident_hex = "".join(f"{b:02X}" for b in ident)
    phone = _bcd_to_digits(ident)
    lines = [
        f"  пакет: {hexs}",
        f"    cmd        = 0x{cmd:02X}",
        f"    ident(hex) = {ident_hex}",
        f"    замок      = 0x{lock:04X} ({lock})",
    ]
    if phone is not None:
        lines.append(f"    BCD-номер  = …{phone[-10:]}  (полностью: {phone})")
    return "\n".join(lines)


def _local_ip() -> str:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "<ваш-IP>"


def main() -> None:
    # Windows-консоль по умолчанию в cp1251 — заставим её принимать UTF-8.
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9999
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen(5)
    print("=" * 56)
    print(" TCP-приёмник пакетов шлюза")
    print("=" * 56)
    print(f"  Слушаю: 0.0.0.0:{port}")
    print(f"  В приложении «Шлюз» → транспорт TCP:")
    print(f"    Хост: {_local_ip()}")
    print(f"    Порт: {port}")
    print("  Ctrl+C — выход")
    print("=" * 56)
    while True:
        conn, addr = srv.accept()
        ts = datetime.now().strftime("%H:%M:%S")
        with conn:
            data = b""
            conn.settimeout(2.0)
            try:
                while True:
                    chunk = conn.recv(64)
                    if not chunk:
                        break
                    data += chunk
            except socket.timeout:
                pass
        print(f"\n[{ts}] от {addr[0]}:{addr[1]}")
        # Поток может содержать несколько 10-байтных пакетов подряд.
        if len(data) % 10 == 0 and len(data) >= 10:
            for i in range(0, len(data), 10):
                print(_describe(data[i:i + 10]))
        else:
            print(_describe(data))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nВыход.")
