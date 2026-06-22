"""Анализ траектории изменения сигнала BLE-метки для контроля доступа.

Ядро ВКР «Разработка системы контроля удалённого доступа на основе анализа
траектории изменения сигнала BLE-меток».

Идея: решение о доступе принимается НЕ по одному замеру RSSI («сигнал сильный →
открыть»), а по ТРАЕКТОРИИ прохождения меткой зон сигнала во времени. Метка должна
сначала устойчиво находиться «далеко», а затем устойчиво войти в зону «близко».
Это отсекает случайные всплески RSSI, статичные далёкие метки и простое
«поднесение» чужого сигнала.

Алгоритм (гистерезис зон, без фильтра Калмана и сглаживания):
    каждое измерение RSSI относится к зоне «далеко» (rssi < B), «близко»
    (rssi > A) или нечувствительности (B ≤ rssi ≤ A); ведутся счётчики времени
    удержания в зонах; доступ выдаётся при удержании «близко» (A > Y) после
    взвода «далеко» (B > X), с защёлкой гистерезиса от повторных открытий.

Запуск демонстрации (симуляция прохода метки + график trajectory_demo.png):
    python trajectory.py
"""
from __future__ import annotations

import math
import random
from dataclasses import dataclass
from enum import Enum

# --------------------------------------------------------------------------- #
# Модель распространения сигнала: RSSI -> расстояние (для расчёта порогов зон)
# --------------------------------------------------------------------------- #

TX_POWER_1M = -59.0   # калиброванный RSSI на расстоянии 1 м, dBm
PATH_LOSS_N = 2.0     # показатель затухания среды (2.0 — свободное пространство)


def rssi_to_distance(rssi: float, tx_power: float = TX_POWER_1M,
                     n: float = PATH_LOSS_N) -> float:
    """Оценка расстояния (м) по RSSI: d = 10^((TxPower - RSSI) / (10*n))."""
    return 10.0 ** ((tx_power - rssi) / (10.0 * n))


# --------------------------------------------------------------------------- #
# Зоны сигнала и счётчики удержания
# --------------------------------------------------------------------------- #


class Zone(str, Enum):
    FAR = "далеко"
    BETWEEN = "между"
    NEAR = "близко"


class ZoneAccessAlgorithm:
    """Алгоритм принятия решения о доступе по гистерезису зон сигнала.

    near_rssi (A) — верхний порог: rssi > A => зона «близко»;
    far_rssi  (B) — нижний порог: rssi < B => зона «далеко»;
    far_hold_x (X) — удержание «далеко» для взвода (B > X);
    near_hold_y (Y) — удержание «близко» для выдачи доступа (A > Y).

    Состояние счётчиков ведётся по ключу метки. Возвращается зона, счётчики и
    признак open — нужно ли на этом измерении предоставить доступ.
    """

    def __init__(self, near_rssi: int = -65, far_rssi: int = -85,
                 far_hold_x: int = 3, near_hold_y: int = 3):
        self.near_rssi = near_rssi
        self.far_rssi = far_rssi
        self.far_hold_x = far_hold_x
        self.near_hold_y = near_hold_y
        # state[id] = [a, b]; b is None пока метка не была «далеко»
        self._state: dict[str, list] = {}

    def push(self, tag_id: str, rssi: float) -> tuple[Zone, int, int | None, bool]:
        st = self._state.setdefault(tag_id, [0, None])  # [a, b]
        a, b = st
        opened = False
        if rssi < self.far_rssi:                         # зона «далеко»
            zone = Zone.FAR
            b = (b or 0) + 1
            a = 0                                        # сброс A только при выходе «далеко»
        elif rssi > self.near_rssi:                      # зона «близко»
            zone = Zone.NEAR
            a += 1                                       # удержание «близко»
            if a > self.near_hold_y:
                if b is not None and b > self.far_hold_x:  # был взвод «далеко»
                    opened = True
                b = 0                                      # защёлка гистерезиса
        else:                                            # зона нечувствительности
            zone = Zone.BETWEEN                           # счётчики без изменений
        st[0], st[1] = a, b
        return zone, a, b, opened

    def remove(self, tag_id: str) -> None:
        """Метка пропала из зоны действия — удаляем её записи."""
        self._state.pop(tag_id, None)


# --------------------------------------------------------------------------- #
# Состояния доступа и точка траектории (для журнала/графиков)
# --------------------------------------------------------------------------- #


class Access(str, Enum):
    FAR = "далеко"
    APPROACHING = "приближается"
    GRANTED = "ДОСТУП РАЗРЕШЁН"
    LEAVING = "удаляется"


@dataclass
class Sample:
    t: float            # время, с
    rssi_raw: float     # сырой RSSI, dBm
    rssi_smooth: float  # = сырой RSSI (сглаживание не применяется)
    distance: float     # оценка расстояния, м (по модели затухания)
    zone: Zone          # зона сигнала на этом измерении
    a: int              # счётчик удержания «близко»
    b: int | None       # счётчик удержания «далеко» (None — ещё не было «далеко»)
    state: Access       # состояние доступа (для визуализации)


# --------------------------------------------------------------------------- #
# Анализатор траектории на основе гистерезиса зон (поток одной метки)
# --------------------------------------------------------------------------- #


class TrajectoryAnalyzer:
    """Принимает поток (t, rssi) одной метки и решает, разрешать ли доступ.

    Обёртка над ZoneAccessAlgorithm для одной метки: добавляет «защёлку
    доступа» для непрерывной индикации состояния GRANTED на графиках и в
    журнале (от момента открытия до ухода метки «далеко»).
    """

    def __init__(self, near_rssi: int = -65, far_rssi: int = -85,
                 far_hold_x: int = 3, near_hold_y: int = 3,
                 tx_power: float = TX_POWER_1M, n: float = PATH_LOSS_N):
        self.algo = ZoneAccessAlgorithm(near_rssi, far_rssi, far_hold_x, near_hold_y)
        self.tx_power = tx_power
        self.n = n
        self.history: list[Sample] = []
        self._granted = False

    def push(self, t: float, rssi: float) -> Sample:
        zone, a, b, opened = self.algo.push("tag", rssi)
        dist = rssi_to_distance(rssi, self.tx_power, self.n)

        if opened:
            self._granted = True
        # Снятие индикации доступа при уходе «далеко» (после взвода).
        if self._granted and zone is Zone.FAR and (b or 0) > self.algo.far_hold_x:
            self._granted = False

        if self._granted:
            state = Access.GRANTED
        elif zone is Zone.NEAR:
            state = Access.APPROACHING
        elif zone is Zone.FAR:
            state = Access.FAR
        else:
            state = Access.APPROACHING if a > 0 else Access.FAR

        s = Sample(t, rssi, rssi, dist, zone, a, b, state)
        self.history.append(s)
        return s


# --------------------------------------------------------------------------- #
# Симуляция прохода метки (для демонстрации без реального хождения с меткой)
# --------------------------------------------------------------------------- #


def simulate_pass(n_samples: int = 60, dt: float = 0.5, d_start: float = 25.0,
                  d_min: float = 1.0, noise_db: float = 4.0,
                  seed: int = 42) -> list[tuple[float, float]]:
    """Сценарий прохода: метка приближается из зоны «далеко» (d_start) к точке
    прохода (d_min), удерживается у неё, затем удаляется обратно.

    Три фазы (по трети измерений): подход → удержание → удаление. Возвращает
    список (t, rssi_с_шумом) — как будто пришёл со сканера.
    """
    rnd = random.Random(seed)
    third = max(1, n_samples // 3)
    series: list[tuple[float, float]] = []
    for i in range(n_samples):
        if i < third:                                            # подход
            d = d_start + (d_min - d_start) * (i / third)
        elif i < 2 * third:                                      # удержание
            d = d_min
        else:                                                    # удаление
            d = d_min + (d_start - d_min) * ((i - 2 * third) /
                                             (n_samples - 2 * third))
        d = max(d, 0.2)
        true_rssi = TX_POWER_1M - 10.0 * PATH_LOSS_N * math.log10(d)
        rssi = true_rssi + rnd.gauss(0.0, noise_db)              # шум датчика
        series.append((i * dt, rssi))
    return series


# --------------------------------------------------------------------------- #
# Демонстрация: симуляция -> анализ -> график + таблица решений
# --------------------------------------------------------------------------- #


def run_demo(out_png: str = "trajectory_demo.png") -> None:
    series = simulate_pass()
    analyzer = TrajectoryAnalyzer()
    samples = [analyzer.push(t, rssi) for t, rssi in series]

    print("t,с   RSSI   дист,м  зона     A  B  состояние")
    prev = None
    granted_at = None
    for s in samples:
        if s.state != prev:
            print(f"{s.t:5.1f} {s.rssi_raw:6.1f} {s.distance:6.2f}  "
                  f"{s.zone.value:8s} {s.a:2d} {('-' if s.b is None else s.b):>2}"
                  f"  {s.state.value}")
        if granted_at is None and s.state == Access.GRANTED:
            granted_at = s.t
        prev = s.state
    if granted_at is not None:
        print(f"\nДоступ разрешён на t = {granted_at:.1f} с")
    else:
        print("\nДоступ не разрешён")

    _plot(samples, analyzer.algo, out_png)
    print(f"График сохранён: {out_png}")


def _plot(samples: list[Sample], algo: ZoneAccessAlgorithm, out_png: str) -> None:
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
    ax.legend(loc="lower center", ncol=2, fontsize=9)
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_png, dpi=130)


if __name__ == "__main__":
    run_demo()
