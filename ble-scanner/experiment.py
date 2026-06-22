"""Натурный эксперимент: запись реального RSSI прохода метки и его анализ.

Закрывает ограничение «всё на симуляции»: позволяет записать РЕАЛЬНЫЙ временной
ряд RSSI при проходе носителя с меткой мимо сканера и прогнать его через тот же
анализатор траектории (`trajectory.TrajectoryAnalyzer`), что и боевой шлюз.

Сценарий эксперимента:
    1. На телефоне включить вещание метки (iBeacon) — вкладка «Метка»/«Генератор».
    2. Запустить запись на ноутбуке:
           python experiment.py record --uuid <UUID> --out pass.csv
       и пройти с телефоном К сканеру и ОБРАТНО (приближение → удаление).
       Ctrl+C — остановить запись.
    3. Построить график и решение на реальных данных:
           python experiment.py analyze pass.csv --out ../diploma/figures/fig_3_5_real_pass.png

Если метку определять по MAC или имени, использовать --mac / --name вместо --uuid.
Без фильтра записывается самый сильный обнаруженный iBeacon.
"""
from __future__ import annotations

import argparse
import asyncio
import csv
import sys
import time
from typing import Optional

from trajectory import Access, TrajectoryAnalyzer

APPLE_MFR_ID = 0x004C


# --------------------------------------------------------------------------- #
# Запись RSSI прохода в CSV
# --------------------------------------------------------------------------- #


def _parse_ibeacon(adv) -> Optional[tuple[str, int, int]]:
    """Возвращает (uuid_hex_no_dashes, major, minor) или None."""
    data = adv.manufacturer_data.get(APPLE_MFR_ID)
    if not data or len(data) < 23 or data[0] != 0x02 or data[1] != 0x15:
        return None
    uuid_hex = bytes(data[2:18]).hex().upper()
    major = (data[18] << 8) | data[19]
    minor = (data[20] << 8) | data[21]
    return uuid_hex, major, minor


async def record(out_csv: str, *, uuid: Optional[str], mac: Optional[str],
                 name: Optional[str], duration: Optional[float]) -> None:
    from bleak import BleakScanner

    want_uuid = (uuid or "").replace("-", "").replace(" ", "").upper() or None
    want_mac = (mac or "").replace(":", "").replace("-", "").upper() or None
    want_name = (name or "").lower() or None

    rows: list[tuple[float, int]] = []
    t0 = time.time()
    last_print = 0.0

    def matches(device, adv) -> bool:
        if want_uuid:
            ib = _parse_ibeacon(adv)
            return ib is not None and ib[0] == want_uuid
        if want_mac:
            addr = (device.address or "").replace(":", "").replace("-", "").upper()
            return addr == want_mac
        if want_name:
            nm = (adv.local_name or device.name or "").lower()
            return want_name in nm
        # без фильтра — любой iBeacon
        return _parse_ibeacon(adv) is not None

    def callback(device, adv) -> None:
        nonlocal last_print
        if not matches(device, adv):
            return
        rssi = adv.rssi if adv.rssi is not None else -100
        t = time.time() - t0
        rows.append((round(t, 3), int(rssi)))
        if t - last_print >= 0.5:
            last_print = t
            bar = "█" * max(0, (rssi + 100) // 3)
            print(f"  t={t:6.1f}s  RSSI={rssi:5d}  {bar}")

    scanner = BleakScanner(detection_callback=callback)
    flt = (f"UUID={want_uuid}" if want_uuid else
           f"MAC={want_mac}" if want_mac else
           f"name~{want_name}" if want_name else "любой iBeacon")
    print(f"Запись RSSI ({flt}). Идите с меткой К сканеру и обратно. Ctrl+C — стоп.\n")

    await scanner.start()
    try:
        if duration:
            await asyncio.sleep(duration)
        else:
            while True:
                await asyncio.sleep(0.25)
    except (KeyboardInterrupt, asyncio.CancelledError):
        pass
    finally:
        try:
            await scanner.stop()
        except Exception:
            pass

    if not rows:
        print("\nНе записано ни одного замера — проверьте, что метка вещает и фильтр верен.")
        return

    with open(out_csv, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["t", "rssi"])
        w.writerows(rows)
    dur = rows[-1][0] - rows[0][0]
    print(f"\nЗаписано {len(rows)} замеров за {dur:.1f} с → {out_csv}")


# --------------------------------------------------------------------------- #
# Анализ записанного CSV анализатором траектории
# --------------------------------------------------------------------------- #


def load_csv(path: str) -> list[tuple[float, float]]:
    series: list[tuple[float, float]] = []
    with open(path, "r", encoding="utf-8") as f:
        reader = csv.reader(f)
        header = next(reader, None)
        for row in reader:
            if len(row) < 2:
                continue
            try:
                series.append((float(row[0]), float(row[1])))
            except ValueError:
                continue
    return series


def analyze(csv_path: str, out_png: str, *, near_rssi: int = -65,
            far_rssi: int = -85, far_hold_x: int = 3, near_hold_y: int = 3) -> None:
    series = load_csv(csv_path)
    if len(series) < 5:
        print(f"Слишком мало данных в {csv_path} ({len(series)} строк).")
        sys.exit(1)

    analyzer = TrajectoryAnalyzer(near_rssi=near_rssi, far_rssi=far_rssi,
                                  far_hold_x=far_hold_x, near_hold_y=near_hold_y)
    samples = [analyzer.push(t, rssi) for t, rssi in series]

    # Сводка переходов состояний
    print("t,с    RSSI  дист,м  зона     A  B  состояние")
    prev = None
    granted_at = None
    for s in samples:
        if s.state != prev:
            print(f"{s.t:6.1f} {s.rssi_raw:6.1f} {s.distance:6.2f}  "
                  f"{s.zone.value:8s} {s.a:2d} {('-' if s.b is None else s.b):>2}"
                  f"  {s.state.value}")
        if granted_at is None and s.state == Access.GRANTED:
            granted_at = s.t
        prev = s.state
    print(f"\nЗамеров: {len(samples)}; длительность: {samples[-1].t - samples[0].t:.1f} с")
    if granted_at is not None:
        print(f"Доступ разрешён на t = {granted_at:.1f} с (реальные данные)")
    else:
        print("Доступ не разрешён (приближение не подтверждено)")

    _plot(samples, analyzer.algo, out_png)
    print(f"График сохранён: {out_png}")


def _plot(samples, algo, out_png: str) -> None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    t = [s.t for s in samples]
    raw = [s.rssi_raw for s in samples]
    granted = [s.t for s in samples if s.state == Access.GRANTED]

    fig, ax = plt.subplots(figsize=(10, 5.5))
    ax.plot(t, raw, "-o", color="#2D8CFF", ms=3, lw=1.2, label="RSSI (измеренный)")
    ax.axhline(algo.near_rssi, color="#22C55E", ls="--",
               label=f"Порог «близко» A = {algo.near_rssi} dBm")
    ax.axhline(algo.far_rssi, color="#E07B39", ls="--",
               label=f"Порог «далеко» B = {algo.far_rssi} dBm")
    if granted:
        ax.axvspan(min(granted), max(granted), color="#22C55E", alpha=0.18,
                   label="Доступ разрешён")
    ax.set_xlabel("Время, с")
    ax.set_ylabel("RSSI, dBm")
    ax.set_title("Натурный эксперимент: траектория RSSI реального прохода и решение")
    ax.legend(loc="lower center", ncol=2, fontsize=9)
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_png, dpi=130)


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #


def main() -> None:
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

    p = argparse.ArgumentParser(
        description="Натурный эксперимент: запись и анализ траектории RSSI.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    pr = sub.add_parser("record", help="Записать RSSI прохода в CSV")
    pr.add_argument("--out", default="pass.csv", help="Файл CSV (по умолчанию pass.csv)")
    pr.add_argument("--uuid", help="iBeacon UUID метки")
    pr.add_argument("--mac", help="MAC устройства")
    pr.add_argument("--name", help="Подстрока имени устройства")
    pr.add_argument("--duration", type=float, help="Длительность, с (иначе до Ctrl+C)")

    pa = sub.add_parser("analyze", help="Проанализировать CSV и построить график")
    pa.add_argument("csv", help="Файл CSV с колонками t,rssi")
    pa.add_argument("--out", default="real_pass.png", help="PNG-график")
    pa.add_argument("--near-rssi", type=int, default=-65, help="Порог «близко» A")
    pa.add_argument("--far-rssi", type=int, default=-85, help="Порог «далеко» B")
    pa.add_argument("--far-hold-x", type=int, default=3, help="Удержание «далеко» X")
    pa.add_argument("--near-hold-y", type=int, default=3, help="Удержание «близко» Y")

    args = p.parse_args()
    if args.cmd == "record":
        asyncio.run(record(args.out, uuid=args.uuid, mac=args.mac,
                           name=args.name, duration=args.duration))
    elif args.cmd == "analyze":
        analyze(args.csv, args.out, near_rssi=args.near_rssi, far_rssi=args.far_rssi,
                far_hold_x=args.far_hold_x, near_hold_y=args.near_hold_y)


if __name__ == "__main__":
    main()
