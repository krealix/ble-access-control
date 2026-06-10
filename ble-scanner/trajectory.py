"""Анализ траектории изменения сигнала BLE-метки для контроля доступа.

Ядро ВКР «Разработка системы контроля удалённого доступа на основе анализа
траектории изменения сигнала BLE-меток».

Идея: решение о доступе принимается НЕ по одному замеру RSSI («сигнал сильный →
открыть»), а по ТРАЕКТОРИИ изменения сигнала во времени — устройство должно
совершить устойчивое ПРИБЛИЖЕНИЕ в зону доступа. Это отсекает случайные всплески
RSSI, статичные далёкие метки и простое «поднесение» чужого сигнала.

Конвейер обработки:
    RSSI(t)  →  фильтр Калмана (сглаживание)  →  оценка дистанции (log-distance
    path loss)  →  тренд (линейная регрессия наклона)  →  конечный автомат
    решения о доступе.

Запуск демонстрации (симуляция прохода метки + график trajectory_demo.png):
    python trajectory.py
"""
from __future__ import annotations

import math
import random
from dataclasses import dataclass
from enum import Enum

# --------------------------------------------------------------------------- #
# Модель распространения сигнала: RSSI -> расстояние
# --------------------------------------------------------------------------- #

TX_POWER_1M = -59.0   # калиброванный RSSI на расстоянии 1 м, dBm
PATH_LOSS_N = 2.0     # показатель затухания среды (2.0 — свободное пространство)


def rssi_to_distance(rssi: float, tx_power: float = TX_POWER_1M,
                     n: float = PATH_LOSS_N) -> float:
    """Оценка расстояния (м) по RSSI: d = 10^((TxPower - RSSI) / (10*n))."""
    return 10.0 ** ((tx_power - rssi) / (10.0 * n))


# --------------------------------------------------------------------------- #
# Фильтр Калмана (1D) — сглаживание шумного RSSI
# --------------------------------------------------------------------------- #


class Kalman1D:
    """Простейший одномерный фильтр Калмана для скалярного RSSI.

    q — шум процесса (доверие к модели), r — шум измерения (доверие к датчику).
    Чем больше r, тем сильнее сглаживание.
    """

    def __init__(self, q: float = 0.05, r: float = 4.0, p: float = 1.0):
        self.q = q
        self.r = r
        self.p = p
        self.x: float | None = None

    def update(self, z: float) -> float:
        if self.x is None:
            self.x = z
            return self.x
        self.p += self.q                      # прогноз
        k = self.p / (self.p + self.r)        # коэффициент Калмана
        self.x += k * (z - self.x)            # коррекция
        self.p *= (1.0 - k)
        return self.x


# --------------------------------------------------------------------------- #
# Состояния доступа и точка траектории
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
    rssi_smooth: float  # сглаженный RSSI, dBm
    distance: float     # оценка расстояния, м
    trend: float        # наклон сглаженного RSSI, dBm/с (>0 — приближается)
    state: Access


# --------------------------------------------------------------------------- #
# Анализатор траектории + конечный автомат решения о доступе
# --------------------------------------------------------------------------- #


class TrajectoryAnalyzer:
    """Принимает поток (t, rssi) и решает, разрешать ли доступ.

    grant_distance   — радиус зоны доступа, м;
    approach_samples — сколько подряд замеров «приближается» нужно для разрешения;
    window           — окно (в замерах) для оценки тренда;
    trend_eps        — порог наклона, dBm/с, выше которого считаем «приближается».
    """

    def __init__(self, grant_distance: float = 2.0, approach_samples: int = 4,
                 window: int = 5, trend_eps: float = 0.2,
                 tx_power: float = TX_POWER_1M, n: float = PATH_LOSS_N):
        self.grant_distance = grant_distance
        self.approach_samples = approach_samples
        self.window = window
        self.trend_eps = trend_eps
        self.tx_power = tx_power
        self.n = n
        self.kalman = Kalman1D()
        self.history: list[Sample] = []
        self._approach_streak = 0
        self._granted = False

    def _trend(self) -> float:
        """Наклон сглаженного RSSI по последним `window` точкам (МНК)."""
        pts = self.history[-self.window:]
        if len(pts) < 2:
            return 0.0
        xs = [p.t for p in pts]
        ys = [p.rssi_smooth for p in pts]
        mx = sum(xs) / len(xs)
        my = sum(ys) / len(ys)
        num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
        den = sum((x - mx) ** 2 for x in xs) or 1e-9
        return num / den

    def push(self, t: float, rssi: float) -> Sample:
        smooth = self.kalman.update(rssi)
        dist = rssi_to_distance(smooth, self.tx_power, self.n)
        self.history.append(Sample(t, rssi, smooth, dist, 0.0, Access.FAR))
        trend = self._trend()
        self.history[-1].trend = trend

        # Счётчик устойчивого приближения
        if trend > self.trend_eps:
            self._approach_streak += 1
        elif trend < -self.trend_eps:
            self._approach_streak = 0

        in_zone = dist <= self.grant_distance

        # Разрешаем доступ: метка в зоне И подтверждён устойчивый подход
        if (not self._granted and in_zone
                and self._approach_streak >= self.approach_samples):
            self._granted = True
        # Гистерезис: сбрасываем, когда метка ушла заметно за пределы зоны
        if self._granted and dist > self.grant_distance * 1.6:
            self._granted = False

        if self._granted:
            state = Access.GRANTED
        elif in_zone or trend > self.trend_eps:
            state = Access.APPROACHING
        elif trend < -self.trend_eps:
            state = Access.LEAVING
        else:
            state = Access.FAR

        self.history[-1].state = state
        return self.history[-1]


# --------------------------------------------------------------------------- #
# Симуляция прохода метки (для демонстрации без реального хождения с меткой)
# --------------------------------------------------------------------------- #


def simulate_pass(n_samples: int = 60, dt: float = 0.5, d_start: float = 8.0,
                  d_min: float = 0.5, noise_db: float = 4.0,
                  seed: int = 42) -> list[tuple[float, float]]:
    """Метка приближается с d_start до d_min и удаляется обратно.

    Возвращает список (t, rssi_с_шумом) — как будто пришёл со сканера.
    """
    rnd = random.Random(seed)
    half = n_samples // 2
    series: list[tuple[float, float]] = []
    for i in range(n_samples):
        if i <= half:
            d = d_start + (d_min - d_start) * (i / half)          # подход
        else:
            d = d_min + (d_start - d_min) * ((i - half) / half)   # уход
        d = max(d, 0.2)
        true_rssi = TX_POWER_1M - 10.0 * PATH_LOSS_N * math.log10(d)
        rssi = true_rssi + rnd.gauss(0.0, noise_db)               # шум датчика
        series.append((i * dt, rssi))
    return series


# --------------------------------------------------------------------------- #
# Демонстрация: симуляция -> анализ -> график + таблица решений
# --------------------------------------------------------------------------- #


def run_demo(out_png: str = "trajectory_demo.png") -> None:
    series = simulate_pass()
    analyzer = TrajectoryAnalyzer(grant_distance=2.0, approach_samples=4)
    samples = [analyzer.push(t, rssi) for t, rssi in series]

    # Печать ключевых переходов состояния
    print("t,с   RSSI   сглаж   дист,м  тренд   состояние")
    prev = None
    granted_at = None
    for s in samples:
        mark = "  <--" if s.state != prev else ""
        if s.state != prev:
            print(f"{s.t:5.1f} {s.rssi_raw:6.1f} {s.rssi_smooth:7.1f} "
                  f"{s.distance:6.2f} {s.trend:6.2f}  {s.state.value}{mark}")
        if granted_at is None and s.state == Access.GRANTED:
            granted_at = s.t
        prev = s.state
    if granted_at is not None:
        print(f"\nДоступ разрешён на t = {granted_at:.1f} с")
    else:
        print("\nДоступ не разрешён")

    _plot(samples, analyzer.grant_distance, out_png)
    print(f"График сохранён: {out_png}")


def _plot(samples: list[Sample], grant_distance: float, out_png: str) -> None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    t = [s.t for s in samples]
    raw = [s.rssi_raw for s in samples]
    smooth = [s.rssi_smooth for s in samples]
    dist = [s.distance for s in samples]
    granted = [s.t for s in samples if s.state == Access.GRANTED]

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(10, 7), sharex=True)

    ax1.plot(t, raw, ".", color="#9AA7BD", label="RSSI (сырой)", alpha=0.6)
    ax1.plot(t, smooth, "-", color="#2D8CFF", linewidth=2,
             label="RSSI (фильтр Калмана)")
    if granted:
        ax1.axvspan(min(granted), max(granted), color="#22C55E", alpha=0.18,
                    label="Доступ разрешён")
    ax1.set_ylabel("RSSI, dBm")
    ax1.legend(loc="lower center", ncol=3, fontsize=9)
    ax1.grid(True, alpha=0.3)

    ax2.plot(t, dist, "-", color="#E07B39", linewidth=2, label="Оценка расстояния")
    ax2.axhline(grant_distance, color="#22C55E", linestyle="--",
                label=f"Зона доступа ≤ {grant_distance:g} м")
    if granted:
        ax2.axvspan(min(granted), max(granted), color="#22C55E", alpha=0.18)
    ax2.set_xlabel("Время, с")
    ax2.set_ylabel("Расстояние, м")
    ax2.legend(loc="upper center", ncol=2, fontsize=9)
    ax2.grid(True, alpha=0.3)

    fig.tight_layout()
    fig.savefig(out_png, dpi=130)


if __name__ == "__main__":
    run_demo()
