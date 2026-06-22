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
from matplotlib.patches import Arc, Rectangle  # noqa: E402

PURPLE, BLUE, DEEPBLUE, ORANGE, GREEN = (
    "#7C4DFF", "#2D8CFF", "#1E66C7", "#E07B39", "#1FA855")
INK, MUTED, RAIL = "#2B3440", "#5B6573", "#8A94A3"


def _lighten(hexc, t):
    h = hexc.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
    return "#%02X%02X%02X" % (int(r + (255 - r) * t), int(g + (255 - g) * t),
                              int(b + (255 - b) * t))


def _stage(ax, x, y, w, h, title, sub, color):
    cx = x + w / 2
    ax.add_patch(FancyBboxPatch((x + 0.045, y - 0.06), w, h,   # мягкая тень
                 boxstyle="round,pad=0.02,rounding_size=0.16",
                 linewidth=0, facecolor="#0B1F33", alpha=0.08, zorder=2))
    ax.add_patch(FancyBboxPatch((x, y), w, h,                  # карточка
                 boxstyle="round,pad=0.02,rounding_size=0.16",
                 linewidth=2.4, edgecolor=color, facecolor=_lighten(color, 0.95),
                 zorder=3))
    # цветной значок-бейдж с инициалом
    ax.add_patch(Ellipse((cx, y + h * 0.855), 0.44, 0.44, facecolor=color,
                 edgecolor="white", linewidth=1.6, zorder=4))
    ax.text(cx, y + h * 0.855, title[0], ha="center", va="center", fontsize=14,
            fontweight="bold", color="white", zorder=5)
    # текст блоков — чёрный; заголовок выше линии потоков, подпись ниже,
    # средняя полоса бокса остаётся свободной для подписей стрелок
    ax.text(cx, y + h * 0.595, title, ha="center", va="center", fontsize=12.5,
            fontweight="bold", color="#111418", zorder=5)
    ax.text(cx, y + h * 0.265, sub, ha="center", va="center", fontsize=11.5,
            color="#111418", zorder=5, linespacing=1.3)


def _flow(ax, x1, y1, x2, y2, label=""):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle="-|>",
                 mutation_scale=15, lw=1.8, color=RAIL, zorder=3,
                 shrinkA=0, shrinkB=0))
    if label:
        ax.text((x1 + x2) / 2, (y1 + y2) / 2, label, ha="center", va="center",
                fontsize=12, color=INK, zorder=5, linespacing=1.1,
                bbox=dict(boxstyle="round,pad=0.3", fc="white", ec="#D6DBE3",
                          lw=0.9))


def _db(ax, cx, cy, w, h, title, color):
    rx, ey, fill = w / 2, 0.16, _lighten(color, 0.9)
    ax.add_patch(Ellipse((cx, cy - h / 2), w, ey * 2, facecolor=fill,
                 edgecolor="none", zorder=2))
    ax.add_patch(Rectangle((cx - rx, cy - h / 2), w, h, facecolor=fill,
                 edgecolor="none", zorder=3))
    ax.plot([cx - rx, cx - rx], [cy - h / 2, cy + h / 2], color=color, lw=1.8,
            zorder=4)
    ax.plot([cx + rx, cx + rx], [cy - h / 2, cy + h / 2], color=color, lw=1.8,
            zorder=4)
    ax.add_patch(Arc((cx, cy - h / 2), w, ey * 2, theta1=180, theta2=360,
                 edgecolor=color, lw=1.8, zorder=4))
    ax.add_patch(Ellipse((cx, cy + h / 2), w, ey * 2,
                 facecolor=_lighten(color, 0.78), edgecolor=color, lw=1.8,
                 zorder=5))
    ax.text(cx, cy, title, ha="center", va="center", fontsize=13,
            fontweight="bold", color=color, zorder=6, linespacing=1.25)


def _group(ax, x, y, w, h, label):
    ax.add_patch(FancyBboxPatch((x, y), w, h,
                 boxstyle="round,pad=0.02,rounding_size=0.05", linewidth=1.3,
                 edgecolor="#B4BCC8", facecolor="none", linestyle=(0, (6, 4)),
                 zorder=1))
    ax.text(x + 0.2, y + h, " " + label + " ", ha="left", va="center",
            fontsize=12.5, color="#717A87", style="italic", zorder=2,
            bbox=dict(boxstyle="round,pad=0.2", fc="white", ec="none"))


fig, ax = plt.subplots(figsize=(10.3, 5.9))
ax.set_xlim(0, 10.3)
ax.set_ylim(0, 5.9)
ax.axis("off")

W, H, YB = 1.5, 2.05, 1.4
xs = [0.28, 2.34, 4.40, 6.46, 8.52]
stages = [
    ("BLE-метка", "источник\nрекламы BLE", PURPLE),
    ("Сканер", "приём\nRSSI(t)", BLUE),
    ("Анализатор", "траектория →\nрешение", DEEPBLUE),
    ("Исполнитель", "HM10:\nBLE → RS-485", ORANGE),
    ("Замок", "электро-\nзамок", GREEN),
]
cy_box = YB + H / 2

# группы (под боксами)
_group(ax, 2.16, 1.15, 3.95, 4.05, "Считыватель")
_group(ax, 6.33, 1.15, 3.81, 2.50, "Исполнительная часть")

# база авторизованных (цилиндр) над анализатором
cx3 = xs[2] + W / 2
_db(ax, cx3, 4.55, 1.85, 0.95, "База\nавторизованных", ORANGE)
_flow(ax, cx3, 4.07, cx3, YB + H, "полно-\nмочия")

# этапы
for x, (title, sub, color) in zip(xs, stages):
    _stage(ax, x, YB, W, H, title, sub, color)

# потоки данных
fl = ["BLE-реклама", "RSSI(t)", "команда 10 Б", "RS-485"]
for i, lab in enumerate(fl):
    _flow(ax, xs[i] + W, cy_box, xs[i + 1], cy_box, lab)

fig.tight_layout()
fig.savefig(os.path.join(OUT, "fig_2_1_architecture.png"), dpi=200)
plt.close()


# ---------- Рисунок 2.2 — блок-схема алгоритма гистерезиса зон ----------
from matplotlib.patches import Polygon  # noqa: E402

A_BLUE, A_ORANGE, A_GREEN, A_GREY = "#2D8CFF", "#E07B39", "#1FA855", "#7A8493"

figA, axA = plt.subplots(figsize=(10.0, 12.0))
axA.set_xlim(0, 12)
axA.set_ylim(0, 14.4)
axA.axis("off")


def aterm(x, y, text, w=4.2, h=1.0):
    axA.add_patch(FancyBboxPatch((x - w / 2 + 0.05, y - h / 2 - 0.07), w, h,
                  boxstyle="round,pad=0.02,rounding_size=0.48", lw=0,
                  facecolor="#000000", alpha=0.06, zorder=1))
    axA.add_patch(FancyBboxPatch((x - w / 2, y - h / 2), w, h,
                  boxstyle="round,pad=0.02,rounding_size=0.48", lw=1.8,
                  edgecolor=A_GREY, facecolor=_lighten(A_GREY, 0.9), zorder=2))
    axA.text(x, y, text, ha="center", va="center", fontsize=16.5,
             fontweight="bold", color="#3A434F", zorder=3)


def aproc(x, y, text, w=3.6, h=1.1, color=A_BLUE):
    axA.add_patch(FancyBboxPatch((x - w / 2 + 0.05, y - h / 2 - 0.07), w, h,
                  boxstyle="round,pad=0.02,rounding_size=0.10", lw=0,
                  facecolor="#000000", alpha=0.06, zorder=1))
    axA.add_patch(FancyBboxPatch((x - w / 2, y - h / 2), w, h,
                  boxstyle="round,pad=0.02,rounding_size=0.10", lw=2.2,
                  edgecolor=color, facecolor=_lighten(color, 0.9), zorder=2))
    axA.text(x, y, text, ha="center", va="center", fontsize=15.5,
             color="#2B3440", zorder=3, linespacing=1.3)


def adia(x, y, text, w=4.0, h=1.9):
    pts = [(x, y + h / 2), (x + w / 2, y), (x, y - h / 2), (x - w / 2, y)]
    sh = [(px + 0.06, py - 0.08) for px, py in pts]
    axA.add_patch(Polygon(sh, closed=True, facecolor="#000000", alpha=0.06,
                  lw=0, zorder=1))
    axA.add_patch(Polygon(pts, closed=True, facecolor=_lighten(A_ORANGE, 0.9),
                  edgecolor=A_ORANGE, linewidth=2.2, zorder=2))
    axA.text(x, y, text, ha="center", va="center", fontsize=15, zorder=3,
             color="#7A4A1E", linespacing=1.3)


def aflow(pts, label="", lp=None, head=True):
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    axA.plot(xs, ys, color=A_GREY, lw=2.2, zorder=2, solid_capstyle="round",
             solid_joinstyle="round")
    if head:
        axA.annotate("", xy=pts[-1], xytext=pts[-2],
                     arrowprops=dict(arrowstyle="-|>", lw=2.2, color=A_GREY))
    if label:
        px, py = lp if lp else ((pts[0][0] + pts[1][0]) / 2,
                                (pts[0][1] + pts[1][1]) / 2)
        axA.text(px, py, label, fontsize=14, fontweight="bold", ha="center",
                 va="center", color="#444", zorder=5,
                 bbox=dict(boxstyle="circle,pad=0.28", fc="white", ec="#C9D0DA",
                           lw=1.1))


SP, LFT, RGT, BUS = 6.0, 2.0, 10.0, 2.25

aterm(SP, 13.6, "Измерение: id, RSSI")
adia(SP, 11.7, "RSSI < B ?\n(зона «далеко»)")
aproc(LFT, 11.7, "B ← B + 1\nA ← 0  (взвод)", w=3.0)
adia(SP, 9.2, "RSSI > A ?\n(зона «близко»)")
aproc(RGT, 9.2, "зона «между»:\nбез изменений", w=3.0)
aproc(SP, 7.0, "A ← A + 1\n(удержание «близко»)", w=3.8)
adia(SP, 4.9, "A > Y  и  B > X ?", w=4.6, h=1.9)
aproc(SP, 3.0, "ОТКРЫТЬ ЗАМОК\nB ← 0  (защёлка)", w=3.8, color=A_GREEN)
aterm(SP, 1.0, "Следующее измерение")

# спинной поток (сверху вниз)
aflow([(SP, 13.10), (SP, 12.68)])
aflow([(SP, 10.75), (SP, 10.18)], "нет", lp=(SP + 0.55, 10.46))
aflow([(SP, 8.25), (SP, 7.58)], "да", lp=(SP + 0.5, 7.9))
aflow([(SP, 6.45), (SP, 5.98)])
aflow([(SP, 3.85), (SP, 3.58)], "да", lp=(SP + 0.5, 3.7))
aflow([(SP, 2.45), (SP, BUS + 0.02)], head=False)

# ветвь «далеко»: D1 «да» → блок → вниз на шину
aflow([(SP - 2.0, 11.7), (LFT + 1.5, 11.7)], "да", lp=(3.6, 12.05))
aflow([(LFT, 11.15), (LFT, BUS)], head=False)
# ветвь «между»: D2 «нет» → блок → вниз на шину
aflow([(SP + 2.0, 9.2), (RGT - 1.5, 9.2)], "нет", lp=(8.4, 9.55))
aflow([(RGT, 8.65), (RGT, BUS)], head=False)
# ветвь D3 «нет» → вправо → вниз на шину
aflow([(SP + 2.6, 4.9), (9.0, 4.9), (9.0, BUS)], "нет", lp=(SP + 3.0, 5.2),
      head=False)
# шина слияния и выход в «Следующее измерение»
axA.plot([LFT, RGT], [BUS, BUS], color=A_GREY, lw=2.2, zorder=2,
         solid_capstyle="round")
aflow([(SP, BUS), (SP, 1.52)])

figA.tight_layout()
figA.savefig(os.path.join(OUT, "fig_2_2_algorithm.png"), dpi=175)
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

an = TrajectoryAnalyzer()
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
