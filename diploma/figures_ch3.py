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
an = TrajectoryAnalyzer()
samples = [an.push(t, r) for t, r in series]
_plot(samples, an.algo, os.path.join(OUT, "fig_3_4_sim_result.png"))

# ---------- Рисунок 3.5 — характерный проход в условиях, приближённых к реальным -
# Повышенный уровень шума и квантование RSSI до целых значений (как у реального
# приёмника), что приближает форму сигнала к натурным измерениям.
series_real = [(t, float(round(r))) for t, r in simulate_pass(noise_db=6.0, seed=7)]
an_real = TrajectoryAnalyzer()
samples_real = [an_real.push(t, r) for t, r in series_real]
granted_real = [s.t for s in samples_real if s.state.value == "ДОСТУП РАЗРЕШЁН"]
print("fig_3_5 grant span:", (min(granted_real), max(granted_real)) if granted_real
      else "НЕТ ДОСТУПА")
_plot(samples_real, an_real.algo, os.path.join(OUT, "fig_3_5_real_pass.png"))

# ---------- Рисунок 3.2 — конвейер обработки входящего пакета в шлюзе ----------
# Поток программной реализации (мониторинг шлюза): от приёма рекламного пакета
# до открытия замка. Сам алгоритм гистерезиса — один блок (ссылка на рис. 4).
fig, ax = plt.subplots(figsize=(9.4, 12.4))
ax.set_xlim(0, 13.2)
ax.set_ylim(0, 15.2)
ax.axis("off")


def proc(x, y, text, w=3.7, h=1.05, fc="#E8EEF7", ec="#2D8CFF", fs=12.5, lw=1.4):
    ax.add_patch(FancyBboxPatch((x - w / 2, y - h / 2), w, h,
                                boxstyle="round,pad=0.02,rounding_size=0.07",
                                lw=lw, edgecolor=ec, facecolor=fc))
    ax.text(x, y, text, ha="center", va="center", fontsize=fs)


def term(x, y, text, w=3.3, h=0.95, fs=12.5):
    ax.add_patch(FancyBboxPatch((x - w / 2, y - h / 2), w, h,
                                boxstyle="round,pad=0.02,rounding_size=0.42",
                                lw=1.4, edgecolor="#666", facecolor="#EEF1F6"))
    ax.text(x, y, text, ha="center", va="center", fontsize=fs)


def dec(x, y, text, w=3.9, h=1.5, fc="#FFF3E0", ec="#E07B39", fs=12.5):
    pts = [(x, y + h / 2), (x + w / 2, y), (x, y - h / 2), (x - w / 2, y)]
    ax.add_patch(Polygon(pts, closed=True, lw=1.4, edgecolor=ec, facecolor=fc))
    ax.text(x, y, text, ha="center", va="center", fontsize=fs)


def seg(pts, label="", lp=None):
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    ax.plot(xs, ys, color="#444", lw=1.3)
    ax.annotate("", xy=pts[-1], xytext=pts[-2],
                arrowprops=dict(arrowstyle="-|>", lw=1.3, color="#444"))
    if label:
        px, py = lp if lp else ((pts[0][0] + pts[1][0]) / 2,
                                (pts[0][1] + pts[1][1]) / 2)
        ax.text(px, py, label, fontsize=12, fontweight="bold", ha="center",
                va="center", color="#333", bbox=dict(boxstyle="round,pad=0.3",
                                                     fc="white", ec="#C9D0DA",
                                                     lw=0.9, alpha=0.95))


MAIN, RIGHT, LEFT = 5.6, 10.6, 2.0
term(MAIN, 14.4, "Приём рекламного\nпакета BLE")
proc(MAIN, 12.9, "Разбор рекламы:\nидентификатор, RSSI")
dec(MAIN, 11.2, "Интервал опроса\nпройден?")
term(RIGHT, 11.2, "Пропуск\nпакета")
proc(MAIN, 9.6, "Сверка с базой\nавторизованных")
proc(MAIN, 8.0, "Алгоритм гистерезиса\nзон (рисунок 4)",
     fc="#DCE9FB", ec="#2D8CFF", lw=2.1)
dec(MAIN, 6.3, "Доступ\nвыдан?")
term(RIGHT, 6.3, "Ожидание\nслед. пакета")
dec(MAIN, 4.5, "Метка в базе?")
proc(LEFT, 4.5, "Два пакета:\n01·нули +\n88/89·ID", w=3.4, h=1.5)
proc(MAIN, 2.8, "Один пакет:\n88·ID/MAC")
proc(MAIN, 1.5, "Отправка по транспорту\n(HM-10 / TCP / HTTP)", w=4.4)
term(MAIN, 0.45, "Открытие замка", w=3.6)

seg([(MAIN, 13.92), (MAIN, 13.45)])
seg([(MAIN, 12.37), (MAIN, 11.95)])
seg([(MAIN, 10.45), (MAIN, 10.15)], "да", lp=(MAIN + 0.5, 10.3))
seg([(MAIN + 1.95, 11.2), (RIGHT - 1.65, 11.2)], "нет", lp=(8.1, 11.5))
seg([(MAIN, 9.05), (MAIN, 8.55)])
seg([(MAIN, 7.45), (MAIN, 7.05)])
seg([(MAIN, 5.55), (MAIN, 5.25)], "да", lp=(MAIN + 0.5, 5.4))
seg([(MAIN + 1.95, 6.3), (RIGHT - 1.65, 6.3)], "нет", lp=(8.1, 6.6))
seg([(MAIN - 1.95, 4.5), (LEFT + 1.7, 4.5)], "да", lp=(3.8, 4.8))
seg([(MAIN, 3.75), (MAIN, 3.35)], "нет", lp=(MAIN + 0.5, 3.55))
seg([(MAIN, 2.27), (MAIN, 2.0)])
seg([(LEFT, 3.75), (LEFT, 1.5), (MAIN - 2.2, 1.5)])
seg([(MAIN, 0.97), (MAIN, 0.93)])

fig.tight_layout()
fig.savefig(os.path.join(OUT, "fig_3_2_flowchart.png"), dpi=175)
plt.close()

print("OK ch3 figures ->", OUT)
