"""Генерация рисунков для главы 1 ВКР."""
import math
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "ble-scanner"))

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

from trajectory import Kalman1D, simulate_pass  # noqa: E402

OUT = os.path.join(os.path.dirname(__file__), "figures")
os.makedirs(OUT, exist_ok=True)

# --- Рисунок 1.1 — RSSI от расстояния при разных n ---
A = -59.0
ds = [0.5 + 0.1 * i for i in range(0, 196)]  # 0.5 .. 20 м
plt.figure(figsize=(9, 5.5))
for n in (2.0, 2.5, 3.0, 3.5):
    plt.plot(ds, [A - 10 * n * math.log10(d) for d in ds], label=f"n = {n}")
plt.xlabel("Расстояние d, м")
plt.ylabel("RSSI, dBm")
plt.title("Зависимость RSSI от расстояния при разных показателях затухания n")
plt.legend()
plt.grid(True, alpha=0.3)
plt.tight_layout()
plt.savefig(os.path.join(OUT, "fig_1_1_rssi_distance.png"), dpi=130)
plt.close()

# --- Рисунок 1.2 — сравнение методов фильтрации ---
series = simulate_pass(n_samples=60, dt=0.5)
t = [x[0] for x in series]
raw = [x[1] for x in series]

k = 5
sma = [sum(raw[max(0, i - k + 1):i + 1]) / len(raw[max(0, i - k + 1):i + 1])
       for i in range(len(raw))]

alpha = 0.3
ema = []
s = None
for z in raw:
    s = z if s is None else alpha * z + (1 - alpha) * s
    ema.append(s)

kf = Kalman1D()
kal = [kf.update(z) for z in raw]

plt.figure(figsize=(10, 5.5))
plt.plot(t, raw, ".", color="#9AA7BD", alpha=0.6, label="RSSI (сырой)")
plt.plot(t, sma, label="SMA (k=5)")
plt.plot(t, ema, label="EMA (α=0.3)")
plt.plot(t, kal, color="#2D8CFF", linewidth=2, label="Фильтр Калмана")
plt.xlabel("Время, с")
plt.ylabel("RSSI, dBm")
plt.title("Сравнение методов фильтрации зашумлённого сигнала RSSI")
plt.legend()
plt.grid(True, alpha=0.3)
plt.tight_layout()
plt.savefig(os.path.join(OUT, "fig_1_2_filtering.png"), dpi=130)
plt.close()

print("OK figures ->", OUT)
