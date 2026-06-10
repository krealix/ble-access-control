"""Генерация рисунков для главы 3 ВКР."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "ble-scanner"))

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.patches import FancyBboxPatch, Polygon  # noqa: E402

from trajectory import TrajectoryAnalyzer, _plot, simulate_pass  # noqa: E402

OUT = os.path.join(os.path.dirname(__file__), "figures")
os.makedirs(OUT, exist_ok=True)

# ---------- Рисунок 3.4 — результат имитационного моделирования ----------
series = simulate_pass()
an = TrajectoryAnalyzer(grant_distance=2.0, approach_samples=4)
samples = [an.push(t, r) for t, r in series]
_plot(samples, an.grant_distance, os.path.join(OUT, "fig_3_4_sim_result.png"))

# ---------- Рисунок 3.2 — блок-схема алгоритма ----------
fig, ax = plt.subplots(figsize=(8, 11))
ax.set_xlim(0, 11)
ax.set_ylim(0, 22)
ax.axis("off")
MX = 4.2  # основная колонка


def proc(y, text, x=MX, w=6.2, h=1.5, fc="#E8EEF7", ec="#2D8CFF", fs=9.5):
    ax.add_patch(FancyBboxPatch((x - w / 2, y - h / 2), w, h,
                                boxstyle="round,pad=0.02,rounding_size=0.1",
                                lw=1.5, edgecolor=ec, facecolor=fc))
    ax.text(x, y, text, ha="center", va="center", fontsize=fs)


def term(y, text, x=MX, w=4.6, h=1.3):
    ax.add_patch(FancyBboxPatch((x - w / 2, y - h / 2), w, h,
                                boxstyle="round,pad=0.02,rounding_size=0.6",
                                lw=1.5, edgecolor="#555", facecolor="#EEF1F6"))
    ax.text(x, y, text, ha="center", va="center", fontsize=9.5)


def dec(y, text, x=MX, w=6.6, h=2.1, fc="#FFF3E0", ec="#E07B39"):
    pts = [(x, y + h / 2), (x + w / 2, y), (x, y - h / 2), (x - w / 2, y)]
    ax.add_patch(Polygon(pts, closed=True, lw=1.5, edgecolor=ec, facecolor=fc))
    ax.text(x, y, text, ha="center", va="center", fontsize=9)


def down(y1, y2, x=MX, label=""):
    ax.annotate("", xy=(x, y2), xytext=(x, y1),
                arrowprops=dict(arrowstyle="-|>", lw=1.4, color="#444"))
    if label:
        ax.text(x + 0.3, (y1 + y2) / 2, label, fontsize=9, ha="left")


term(21.0, "Начало: (t, RSSI)")
proc(18.5, "Сглаживание Калмана → s")
proc(16.0, "Оценка расстояния d по (2)")
proc(13.5, "Тренд k — наклон по окну (4)")
proc(10.8, "Обновление счётчика приближений\n(k > ε: +1;  k < −ε: 0)")
dec(7.8, "d ≤ d_зоны\nи счётчик ≥ N ?")
proc(7.8, "разрешён =\nистина", x=9.0, w=3.2, h=1.5, fc="#E3F5E9", ec="#22C55E")
proc(4.6, "Определение состояния\n(FAR / APPROACHING /\nGRANTED / LEAVING)")
term(1.8, "Возврат: состояние, d, k")

down(20.35, 19.25)
down(17.75, 16.75)
down(15.25, 14.25)
down(12.75, 11.55)
down(10.05, 8.85)
down(6.75, 5.35, label="нет")
down(5.35 - 1.55 + 0.05, 2.45)  # состояние -> возврат
# ветка "да": ромб -> бокс справа -> вниз -> состояние
ax.annotate("", xy=(7.4, 7.8), xytext=(7.5, 7.8),
            arrowprops=dict(arrowstyle="-|>", lw=1.4, color="#444"))
ax.text(7.45, 8.1, "да", fontsize=9, ha="center")
ax.annotate("", xy=(6.0, 4.9), xytext=(9.0, 7.05),
            arrowprops=dict(arrowstyle="-|>", lw=1.4, color="#444"))

fig.tight_layout()
fig.savefig(os.path.join(OUT, "fig_3_2_flowchart.png"), dpi=130)
plt.close()

print("OK ch3 figures ->", OUT)
