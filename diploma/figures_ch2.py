"""Генерация рисунков для главы 2 ВКР."""
import math
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "ble-scanner"))

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.patches import Ellipse, FancyArrowPatch, FancyBboxPatch  # noqa: E402

from trajectory import Access, TrajectoryAnalyzer  # noqa: E402

OUT = os.path.join(os.path.dirname(__file__), "figures")
os.makedirs(OUT, exist_ok=True)


# ---------- Рисунок 2.1 — структурная схема ----------
def _box(ax, x, y, w, h, text, fc="#E8EEF7", ec="#2D8CFF"):
    ax.add_patch(FancyBboxPatch((x, y), w, h,
                                boxstyle="round,pad=0.02,rounding_size=0.08",
                                linewidth=1.5, edgecolor=ec, facecolor=fc))
    ax.text(x + w / 2, y + h / 2, text, ha="center", va="center", fontsize=10)


def _arrow(ax, x1, y1, x2, y2, label=""):
    ax.annotate("", xy=(x2, y2), xytext=(x1, y1),
                arrowprops=dict(arrowstyle="-|>", lw=1.5, color="#444"))
    if label:
        ax.text((x1 + x2) / 2, (y1 + y2) / 2 + 0.1, label, ha="center",
                va="bottom", fontsize=8, color="#333")


fig, ax = plt.subplots(figsize=(12.5, 3.4))
ax.set_xlim(0, 12.4)
ax.set_ylim(0, 3.4)
ax.axis("off")
w, h, y = 2.0, 1.0, 0.9
xs = [0.1, 2.6, 5.1, 7.6, 10.1]
labels = ["BLE-метка\n(носитель)", "Сканер\nRSSI(t)", "Анализатор\nтраектории",
          "Исполнитель\nHM10 → RS-485", "Замок"]
for x, lab in zip(xs, labels):
    _box(ax, x, y, w, h, lab)
_arrow(ax, 2.1, y + h / 2, 2.6, y + h / 2, "BLE реклама")
_arrow(ax, 4.6, y + h / 2, 5.1, y + h / 2, "RSSI(t)")
_arrow(ax, 7.1, y + h / 2, 7.6, y + h / 2, "команда 10 Б")
_arrow(ax, 9.6, y + h / 2, 10.1, y + h / 2, "RS-485")
_box(ax, 5.1, 2.4, 2.0, 0.7, "База\nавторизованных", fc="#FFF3E0", ec="#E07B39")
_arrow(ax, 6.1, 2.4, 6.1, y + h)
fig.tight_layout()
fig.savefig(os.path.join(OUT, "fig_2_1_architecture.png"), dpi=130)
plt.close()


# ---------- Рисунок 2.2 — граф состояний конечного автомата ----------
fig, ax = plt.subplots(figsize=(9.5, 6.5))
ax.set_xlim(0, 10)
ax.set_ylim(0, 8)
ax.axis("off")


def _node(x, y, text, fc):
    ax.add_patch(Ellipse((x, y), 2.8, 1.4, facecolor=fc, edgecolor="#333", lw=1.5))
    ax.text(x, y, text, ha="center", va="center", fontsize=9)


def _edge(p1, p2, label, rad=0.2):
    ax.add_patch(FancyArrowPatch(p1, p2, connectionstyle=f"arc3,rad={rad}",
                                 arrowstyle="-|>", mutation_scale=15, lw=1.3,
                                 color="#555"))
    ax.text((p1[0] + p2[0]) / 2, (p1[1] + p2[1]) / 2, label, fontsize=8.5,
            ha="center", va="center",
            bbox=dict(boxstyle="round", fc="white", ec="none", alpha=0.85))


FAR, APP, GRA, LEA = (2, 4), (5, 6.4), (8, 4), (5, 1.6)
_node(*FAR, "Далеко\n(FAR)", "#EEF1F6")
_node(*APP, "Приближается\n(APPROACHING)", "#E8EEF7")
_node(*GRA, "Доступ разрешён\n(GRANTED)", "#E3F5E9")
_node(*LEA, "Удаляется\n(LEAVING)", "#FBEAEA")
_edge((2.9, 4.5), (3.9, 6.0), "k > ε")
_edge((6.1, 6.0), (7.1, 4.5), "в зоне\nи N")
_edge((8.0, 3.3), (5.8, 2.0), "d > 1,6·d_зоны")
_edge((4.2, 2.0), (2.3, 3.3), "|k| ≤ ε")
_edge((4.7, 5.7), (4.7, 2.3), "k < −ε", rad=0.0)
fig.tight_layout()
fig.savefig(os.path.join(OUT, "fig_2_2_fsm.png"), dpi=130)
plt.close()


# ---------- Рисунок 2.3 — пороговый подход vs анализ траектории ----------
rnd = random.Random(7)
A, n = -59.0, 2.0
base = A - 10 * n * math.log10(5.0)          # статичная метка на ~5 м
T = A - 10 * n * math.log10(2.0)             # порог, соответствующий зоне 2 м
t, raw = [], []
for i in range(60):
    r = base + rnd.gauss(0, 4.5)
    if i in (12, 28, 41):                     # случайные всплески
        r += rnd.uniform(9, 13)
    t.append(i * 0.5)
    raw.append(r)

an = TrajectoryAnalyzer(grant_distance=2.0, approach_samples=4)
states = [an.push(tt, rr).state for tt, rr in zip(t, raw)]
traj_granted = any(s == Access.GRANTED for s in states)
fires = [(tt, rr) for tt, rr in zip(t, raw) if rr > T]

plt.figure(figsize=(10, 5.5))
plt.plot(t, raw, "-o", color="#9AA7BD", ms=3, lw=0.8, label="RSSI (сырой)")
plt.axhline(T, color="#E74C5C", ls="--", label=f"Порог доступа ({T:.0f} dBm)")
if fires:
    plt.scatter([x for x, _ in fires], [y for _, y in fires], color="#E74C5C",
                zorder=5, label="Пороговый подход: ложное срабатывание")
plt.xlabel("Время, с")
plt.ylabel("RSSI, dBm")
txt = "Анализ траектории: доступ " + ("ПРЕДОСТАВЛЕН" if traj_granted else "не предоставлен")
plt.gca().text(0.02, 0.06, txt, transform=plt.gca().transAxes, fontsize=10,
               color="#1B7F3B",
               bbox=dict(boxstyle="round", fc="#E3F5E9", ec="#22C55E"))
plt.legend(loc="upper right", fontsize=9)
plt.grid(True, alpha=0.3)
plt.tight_layout()
plt.savefig(os.path.join(OUT, "fig_2_3_threshold_vs_trajectory.png"), dpi=130)
plt.close()

print(f"OK figures -> {OUT}  (traj_granted={traj_granted}, threshold_fires={len(fires)})")
