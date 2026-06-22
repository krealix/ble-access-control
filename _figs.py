# -*- coding: utf-8 -*-
"""Генерация 4 рисунков для презентации ВКР (палитра деки)."""
import io, csv, os, math
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Polygon, FancyArrowPatch, Rectangle
from matplotlib.lines import Line2D
import matplotlib.font_manager as fm

# Шрифт: Calibri если есть, иначе DejaVu Sans (Cyrillic ok)
for fam in ("Calibri", "Segoe UI", "DejaVu Sans"):
    try:
        fm.findfont(fam, fallback_to_default=False); plt.rcParams["font.family"] = fam; break
    except Exception:
        continue
plt.rcParams["axes.unicode_minus"] = False

ROOT = r"C:\Users\krealix\Desktop\Новая папка (3)"
OUT = os.path.join(ROOT, "_assets")
os.makedirs(OUT, exist_ok=True)

# --- палитра деки ---
NAVY="#0E2A47"; TEAL="#0E9AA7"; TEAL2="#27C2B6"; GREEN="#2BA84A"; RED="#D9534F"
AMBER="#E0A23B"; CARD="#EEF3F8"; MUTED="#5B6B7B"; LINE="#D4DEE8"; INK="#1E2A38"

def _light(hexc, t):
    h=hexc.lstrip("#"); r,g,b=(int(h[i:i+2],16) for i in (0,2,4))
    return "#%02X%02X%02X"%(int(r+(255-r)*t),int(g+(255-g)*t),int(b+(255-b)*t))

# ======================================================================
# Рисунок 1 — Средний RSSI на разном расстоянии (натурные измерения)
# ======================================================================
dist=[1,2,3,5,8,15]
mean=[-65.2,-70.0,-70.0,-69.6,-86.5,-90.2]
sd=[4.9,5.5,3.1,1.3,3.1,4.0]
nobs=[73,97,124,128,81,118]

fig,ax=plt.subplots(figsize=(8.6,5.0))
NEAR=-65; FAR=-75
# зоны
ax.axhspan(-55,NEAR,color=_light(GREEN,0.86),zorder=0)
ax.axhspan(NEAR,FAR,color=_light(AMBER,0.86),zorder=0)
ax.axhspan(FAR,-100,color=_light(RED,0.88),zorder=0)
ax.axhline(NEAR,color=GREEN,lw=1.4,ls="--",zorder=2)
ax.axhline(FAR,color=RED,lw=1.4,ls="--",zorder=2)
ax.text(15.3,NEAR+0.4,"порог «близко»  A = −65 дБм",color=GREEN,fontsize=9.5,
        ha="right",va="bottom",fontweight="bold")
ax.text(15.3,FAR-1.2,"порог «далеко»  B = −75 дБм",color=RED,fontsize=9.5,
        ha="right",va="top",fontweight="bold")
# измерения
ax.errorbar(dist,mean,yerr=sd,fmt="-o",color=NAVY,ecolor=TEAL,elinewidth=2.2,
            capsize=5,capthick=2.2,ms=9,mfc=TEAL2,mec=NAVY,mew=1.8,lw=2.4,
            zorder=5,label="средний RSSI ± СКО (натурные измерения)")
for d,m,s,nn in zip(dist,mean,sd,nobs):
    ax.annotate(f"{m:.0f}",(d,m),textcoords="offset points",xytext=(0,11+ (3 if s<2 else 0)),
                ha="center",fontsize=10,fontweight="bold",color=NAVY,zorder=6)
# плато 2–5 м
ax.annotate("плато 2–5 м: RSSI ≈ −70 дБм\nодин порог не различает\nэти расстояния → нужен\nанализ траектории",
            xy=(3,-70),xytext=(3.4,-60.5),fontsize=9.3,color=INK,ha="left",va="top",
            bbox=dict(boxstyle="round,pad=0.4",fc="white",ec=AMBER,lw=1.4),
            arrowprops=dict(arrowstyle="-|>",color=AMBER,lw=1.8),zorder=7)
ax.set_xscale("log")
ax.set_xticks(dist); ax.set_xticklabels([str(d) for d in dist])
ax.set_xlim(0.85,17.5); ax.set_ylim(-97,-55)
ax.set_xlabel("Расстояние до метки, м",fontsize=11.5)
ax.set_ylabel("RSSI, дБм",fontsize=11.5)
ax.set_title("Средний уровень сигнала метки на разном расстоянии\n(натурные измерения, 6 точек, n=73…128 отсчётов)",
             fontsize=12.5,fontweight="bold",color=NAVY)
ax.grid(True,which="both",axis="x",alpha=0.25)
ax.legend(loc="upper right",fontsize=9.5,framealpha=0.95)
ax.tick_params(labelsize=10)
fig.tight_layout()
fig.savefig(os.path.join(OUT,"fig_dist_rssi.png"),dpi=200,facecolor="white")
plt.close()

# ======================================================================
# Рисунок 2 — Гистерезис на реальных данных (algo_log 4, STOWN-метка)
# ======================================================================
series=[]
with io.open(os.path.join(ROOT,"_traj_log4.csv"),encoding="utf-8") as f:
    rd=csv.DictReader(f)
    for r in rd:
        series.append((float(r["t"]),int(r["rssi"]),r["zone"],int(r["A"]),int(r["B"]),int(r["open"])))
t=[s[0] for s in series]; rssi=[s[1] for s in series]
A=[s[3] for s in series]; B=[s[4] for s in series]
opens=[s for s in series if s[5]]
topen=opens[0][0]; ropen=opens[0][1]
Y=5  # OPEN на A==6 => Y=5
NEAR=-65; FAR=-75

fig,(ax1,ax2)=plt.subplots(2,1,figsize=(9.5,7.1),sharex=True,
                           gridspec_kw=dict(height_ratios=[1.35,1.0],hspace=0.12))
# --- панель 1: RSSI ---
ax1.axhspan(-48,NEAR,color=_light(GREEN,0.88),zorder=0)
ax1.axhspan(NEAR,FAR,color=_light(AMBER,0.88),zorder=0)
ax1.axhspan(FAR,-100,color=_light(RED,0.90),zorder=0)
ax1.axhline(NEAR,color=GREEN,lw=1.3,ls="--",zorder=2)
ax1.axhline(FAR,color=RED,lw=1.3,ls="--",zorder=2)
ax1.plot(t,rssi,"-",color=NAVY,lw=1.7,zorder=4)
ax1.plot(t,rssi,"o",color=NAVY,ms=2.6,zorder=4)
ax1.axvline(topen,color=GREEN,lw=2.0,zorder=5)
ax1.plot([topen],[ropen],marker="*",ms=20,color=GREEN,mec="white",mew=1.2,zorder=7)
ax1.annotate("ДОСТУП РАЗРЕШЁН",(topen,ropen),xytext=(topen+1.6,-54),
             fontsize=11,fontweight="bold",color=GREEN,va="center",ha="left",
             bbox=dict(boxstyle="round,pad=0.35",fc="white",ec=GREEN,lw=1.6),
             arrowprops=dict(arrowstyle="-|>",color=GREEN,lw=1.7),zorder=8)
ax1.text(0.7,NEAR+0.7,"«близко» (A)",color=GREEN,fontsize=9.5,fontweight="bold",va="bottom")
ax1.text(0.7,(NEAR+FAR)/2,"«между» (гистерезис)",color="#9A7B22",fontsize=9.5,fontweight="bold",va="center")
ax1.text(0.7,FAR-0.8,"«далеко» (B)",color=RED,fontsize=9.5,fontweight="bold",va="top")
ax1.set_ylim(-97,-48); ax1.set_xlim(0,69); ax1.set_ylabel("RSSI, дБм",fontsize=11)
ax1.set_title("Работа алгоритма гистерезиса на реальном проходе носителя\n(STOWN-метка, журнал сканера, 4 изм./с)",
              fontsize=13,fontweight="bold",color=NAVY,pad=10)
ax1.tick_params(labelsize=9.5)
# --- панель 2: счётчики A, B ---
ax2.fill_between(t,0,B,step="pre",color=_light(RED,0.55),zorder=2,label="B — взвод «далеко»")
ax2.plot(t,B,drawstyle="steps-pre",color=RED,lw=1.6,zorder=3)
ax2.fill_between(t,0,A,step="pre",color=_light(GREEN,0.45),zorder=4,label="A — удержание «близко»")
ax2.plot(t,A,drawstyle="steps-pre",color=GREEN,lw=2.0,zorder=5)
ax2.axhline(Y,color=NAVY,lw=1.3,ls=":",zorder=3)
ax2.text(0.6,Y+1.5,"порог удержания Y = 5",color=NAVY,fontsize=9,fontweight="bold")
ax2.axvline(topen,color=GREEN,lw=2.0,zorder=6)
ax2.annotate("A > Y  и  взвод выполнен (B > X)\n→ открытие, защёлка B ← 0",
             xy=(topen,6),xytext=(13,70),fontsize=9.2,color=INK,va="center",ha="center",
             bbox=dict(boxstyle="round,pad=0.35",fc="white",ec=GREEN,lw=1.4),
             arrowprops=dict(arrowstyle="-|>",color=GREEN,lw=1.7),zorder=8)
ax2.annotate("повторный подход «близко»\nбез нового взвода →\nдоступ НЕ выдаётся",
             xy=(56,26),xytext=(67.5,74),fontsize=9.0,color=INK,ha="right",va="top",
             bbox=dict(boxstyle="round,pad=0.35",fc="white",ec=AMBER,lw=1.4),
             arrowprops=dict(arrowstyle="-|>",color=AMBER,lw=1.6),zorder=8)
ax2.set_ylim(0,104); ax2.set_xlim(0,69)
ax2.set_xlabel("Время, с",fontsize=11); ax2.set_ylabel("Счётчик, изм.",fontsize=11)
ax2.legend(loc="upper left",fontsize=9,framealpha=0.95,ncol=2)
ax2.tick_params(labelsize=9.5); ax2.grid(True,axis="y",alpha=0.25)
fig.tight_layout()
fig.savefig(os.path.join(OUT,"fig_hyst_real.png"),dpi=200,facecolor="white")
plt.close()

print("OK figs 1,2")
