# -*- coding: utf-8 -*-
"""Красивая блок-схема алгоритма гистерезиса (слайд 8). Логика идентична рис. 2.2."""
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Polygon, Arc, Circle
import matplotlib.font_manager as fm
for fam in ("Calibri", "Segoe UI", "DejaVu Sans"):
    try:
        fm.findfont(fam, fallback_to_default=False); plt.rcParams["font.family"] = fam; break
    except Exception:
        continue
plt.rcParams["axes.unicode_minus"] = False
OUT = os.path.join(r"C:\Users\krealix\Desktop\Новая папка (3)", "_assets")

NAVY="#0E2A47"; TEAL="#0E9AA7"; GREEN="#2BA84A"; RED="#D9534F"; AMBER="#E0A23B"
SLATE="#8A94A3"; INK="#2B3440"; BLUE="#2D8CFF"
def _light(h,t):
    h=h.lstrip("#"); r,g,b=(int(h[i:i+2],16) for i in (0,2,4))
    return "#%02X%02X%02X"%(int(r+(255-r)*t),int(g+(255-g)*t),int(b+(255-b)*t))

fig, ax = plt.subplots(figsize=(8.0, 9.6)); ax.set_xlim(0,12); ax.set_ylim(0,14.4); ax.axis("off")

def _shadow(x,y,w,h,rs):
    ax.add_patch(FancyBboxPatch((x-w/2+0.09,y-h/2-0.13),w,h,boxstyle="round,pad=0,rounding_size=%f"%rs,
                 facecolor="#0B1F33",alpha=0.06,lw=0,zorder=1))

def aterm(x,y,text,w=4.6,h=1.1):
    rs=h*0.5; _shadow(x,y,w,h,rs)
    ax.add_patch(FancyBboxPatch((x-w/2,y-h/2),w,h,boxstyle="round,pad=0,rounding_size=%f"%rs,
                 facecolor=_light(TEAL,0.86),edgecolor=TEAL,lw=2.0,zorder=3))
    ax.text(x,y,text,ha="center",va="center",fontsize=16,fontweight="bold",color=NAVY,zorder=4)

def aproc(x,y,text,w=3.7,h=1.2,color=BLUE):
    rs=0.16; _shadow(x,y,w,h,rs)
    ax.add_patch(FancyBboxPatch((x-w/2,y-h/2),w,h,boxstyle="round,pad=0,rounding_size=%f"%rs,
                 facecolor=_light(color,0.92),edgecolor=color,lw=2.4,zorder=3))
    ax.text(x,y,text,ha="center",va="center",fontsize=15,color=INK,zorder=4,linespacing=1.3)

def adia(x,y,text,w=4.2,h=1.95,color=AMBER):
    pts=[(x,y+h/2),(x+w/2,y),(x,y-h/2),(x-w/2,y)]
    ax.add_patch(Polygon([(px+0.09,py-0.13) for px,py in pts],closed=True,facecolor="#0B1F33",alpha=0.06,lw=0,zorder=1))
    ax.add_patch(Polygon(pts,closed=True,facecolor=_light(color,0.92),edgecolor=color,lw=2.4,zorder=3))
    ax.text(x,y,text,ha="center",va="center",fontsize=14.5,color=INK,zorder=4,linespacing=1.3)

def lock_icon(cx,cy,s):
    bw=s*0.78; bh=s*0.6
    ax.add_patch(Arc((cx,cy+bh*0.42),bw*0.72,bw*0.82,theta1=0,theta2=180,edgecolor="white",lw=2.6,zorder=5))
    ax.add_patch(FancyBboxPatch((cx-bw/2,cy-bh/2-s*0.04),bw,bh,boxstyle="round,pad=0,rounding_size=%f"%(s*0.1),
                 facecolor="white",edgecolor="none",zorder=5))
    ax.add_patch(Circle((cx,cy-s*0.02),s*0.1,facecolor=GREEN,zorder=6))

def action(x,y,text,w=4.0,h=1.35):
    rs=0.16; _shadow(x,y,w,h,rs)
    ax.add_patch(FancyBboxPatch((x-w/2,y-h/2),w,h,boxstyle="round,pad=0,rounding_size=%f"%rs,
                 facecolor=GREEN,edgecolor="#1E7E34",lw=1.4,zorder=3))
    lock_icon(x-w/2+0.62,y,0.62)
    ax.text(x+0.35,y,text,ha="center",va="center",fontsize=15,fontweight="bold",color="white",zorder=4,linespacing=1.3)

def aflow(pts,label="",ok=None,lp=None,head=True):
    ax.plot([p[0] for p in pts],[p[1] for p in pts],color=SLATE,lw=2.4,zorder=2,
            solid_capstyle="round",solid_joinstyle="round")
    if head:
        ax.annotate("",xy=pts[-1],xytext=pts[-2],arrowprops=dict(arrowstyle="-|>",lw=2.4,color=SLATE))
    if label:
        px,py=lp if lp else ((pts[0][0]+pts[1][0])/2,(pts[0][1]+pts[1][1])/2)
        ax.text(px,py,label,fontsize=13,fontweight="bold",ha="center",va="center",color="white",zorder=6,
                bbox=dict(boxstyle="round,pad=0.32",fc=(GREEN if ok else SLATE),ec="none"))

SP, LFT, RGT, BUS = 6.0, 2.0, 10.0, 2.25

aterm(SP,13.6,"Измерение: id, RSSI")
adia(SP,11.7,"RSSI < B ?\n(зона «далеко»)",color=RED)
aproc(LFT,11.7,"B ← B + 1\nA ← 0   (взвод)",w=3.0,color=RED)
adia(SP,9.2,"RSSI > A ?\n(зона «близко»)",color=GREEN)
aproc(RGT,9.2,"зона «между»:\nбез изменений",w=3.0,color=AMBER)
aproc(SP,7.0,"A ← A + 1\n(удержание «близко»)",w=3.9,color=GREEN)
adia(SP,4.9,"A > Y  и  B > X ?",w=4.7,h=1.95,color=TEAL)
action(SP,3.0,"ОТКРЫТЬ ЗАМОК\nB ← 0  (защёлка)",w=4.0)
aterm(SP,1.0,"Следующее измерение")

# спинной поток
aflow([(SP,13.05),(SP,12.69)])
aflow([(SP,10.72),(SP,10.18)],"нет",ok=False,lp=(SP+0.6,10.45))
aflow([(SP,8.22),(SP,7.62)],"да",ok=True,lp=(SP+0.55,7.92))
aflow([(SP,6.40),(SP,5.90)])
aflow([(SP,3.92),(SP,3.70)],"да",ok=True,lp=(SP+0.55,3.81))
aflow([(SP,2.33),(SP,BUS+0.02)],head=False)
# ветвь «далеко» (да → взвод → шина)
aflow([(SP-2.1,11.7),(LFT+1.5,11.7)],"да",ok=True,lp=(3.7,12.08))
aflow([(LFT,11.10),(LFT,BUS)],head=False)
# ветвь «между» (нет → блок → шина)
aflow([(SP+2.1,9.2),(RGT-1.5,9.2)],"нет",ok=False,lp=(8.3,9.58))
aflow([(RGT,8.60),(RGT,BUS)],head=False)
# ветвь D3 «нет» → вправо → шина
aflow([(SP+2.65,4.9),(9.0,4.9),(9.0,BUS)],"нет",ok=False,lp=(9.0,5.25),head=False)
# шина слияния и выход
ax.plot([LFT,RGT],[BUS,BUS],color=SLATE,lw=2.4,zorder=2,solid_capstyle="round")
aflow([(SP,BUS),(SP,1.55)])

fig.savefig(os.path.join(OUT,"fig_algo.png"),dpi=200,facecolor="white",bbox_inches="tight",pad_inches=0.1)
plt.close(); print("OK algo fig")
