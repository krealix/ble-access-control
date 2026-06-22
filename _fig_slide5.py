# -*- coding: utf-8 -*-
"""Инфографика-контент для слайда 5 «Методы и средства» с логотипами."""
import os, numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import (FancyBboxPatch, Polygon, Rectangle, Circle,
                                Ellipse, Wedge, FancyArrowPatch)
import matplotlib.font_manager as fm
for fam in ("Calibri", "Segoe UI", "DejaVu Sans"):
    try:
        fm.findfont(fam, fallback_to_default=False); plt.rcParams["font.family"] = fam; break
    except Exception:
        continue
plt.rcParams["axes.unicode_minus"] = False
OUT = os.path.join(r"C:\Users\krealix\Desktop\Новая папка (3)", "_assets")

NAVY="#0E2A47"; TEAL="#0E9AA7"; TEAL2="#27C2B6"; INK="#1E2A38"; MUTED="#5B6B7B"
CARD="#F2F7FB"; BORD="#DBE5EE"
FL_LT="#54C5F8"; FL_DK="#0175C2"; AND="#3DDC84"; BT="#1592E6"
def _light(h,t):
    h=h.lstrip("#"); r,g,b=(int(h[i:i+2],16) for i in (0,2,4))
    return "#%02X%02X%02X"%(int(r+(255-r)*t),int(g+(255-g)*t),int(b+(255-b)*t))

# ---------- логотипы ----------
def flutter(ax, cx, cy, s):
    paths=[([(157.666,0),(0,158.667),(48.8,207.467),(255.267,0)], FL_LT),
           ([(156.4,145.4),(72,229.8),(120.9,279),(169.6,230.2),(256.2,143.6)], FL_LT),
           ([(120.9,279),(158,316.1),(255.3,316.1),(169.6,230.3)], FL_DK)]
    for pts,col in paths:
        P=[(cx+(x-128)/317.0*s, cy+(158.5-y)/317.0*s) for x,y in pts]
        ax.add_patch(Polygon(P, closed=True, facecolor=col, edgecolor="none", zorder=6))

def android(ax, cx, cy, s):
    r=s*0.42
    ax.add_patch(Wedge((cx,cy-s*0.06), r, 0, 180, facecolor=AND, edgecolor="none", zorder=6))
    for sgn in (-1,1):
        x0=cx+sgn*r*0.5; y0=cy-s*0.06+r*0.82
        ax.plot([x0,x0+sgn*0.16*s],[y0,y0+0.24*s], color=AND, lw=2.0,
                solid_capstyle="round", zorder=5)
        ax.add_patch(Circle((cx+sgn*r*0.4, cy-s*0.06+r*0.42), r*0.10,
                     facecolor="white", edgecolor="none", zorder=7))

def bluetooth(ax, cx, cy, s):
    ax.add_patch(FancyBboxPatch((cx-s*0.5,cy-s*0.5), s, s,
                 boxstyle="round,pad=0,rounding_size=%f"%(s*0.24),
                 facecolor=BT, edgecolor="none", zorder=6))
    h=s*0.32; w=s*0.18
    pts=[(cx,cy-h),(cx+w,cy-h*0.5),(cx-w,cy+h*0.5),(cx,cy+h),
         (cx,cy-h),(cx-w,cy-h*0.5),(cx+w,cy+h*0.5),(cx,cy+h)]
    ax.plot([p[0] for p in pts],[p[1] for p in pts], color="white", lw=2.6,
            solid_capstyle="round", solid_joinstyle="round", zorder=7)

# ---------- абстрактные иконки ----------
def ic_shield(ax, cx, cy, s, c=TEAL):
    w=s*0.62
    pts=[(cx,cy+s*0.52),(cx+w*0.5,cy+s*0.3),(cx+w*0.5,cy-s*0.12),
         (cx,cy-s*0.52),(cx-w*0.5,cy-s*0.12),(cx-w*0.5,cy+s*0.3)]
    ax.add_patch(Polygon(pts, closed=True, facecolor=_light(c,0.82), edgecolor=c, lw=2.2, zorder=6))
    ax.add_patch(Circle((cx,cy+s*0.1), s*0.1, facecolor=c, edgecolor="none", zorder=7))
    ax.add_patch(Polygon([(cx-s*0.055,cy+s*0.1),(cx+s*0.055,cy+s*0.1),
                 (cx+s*0.03,cy-s*0.2),(cx-s*0.03,cy-s*0.2)], closed=True,
                 facecolor=c, edgecolor="none", zorder=7))

def ic_db(ax, cx, cy, s, c=TEAL):
    rx=s*0.4; ry=s*0.12; top=cy+s*0.4; bot=cy-s*0.4
    ax.add_patch(Rectangle((cx-rx,bot), 2*rx, top-bot, facecolor=_light(c,0.82),
                 edgecolor="none", zorder=5))
    ax.plot([cx-rx,cx-rx],[bot,top], color=c, lw=2.2, zorder=6)
    ax.plot([cx+rx,cx+rx],[bot,top], color=c, lw=2.2, zorder=6)
    ax.add_patch(Wedge((cx,bot), rx, 180, 360, width=0, edgecolor=c, lw=2.2, zorder=6))
    ax.add_patch(Ellipse((cx,bot), 2*rx, 2*ry, facecolor="none", edgecolor=c, lw=2.2, zorder=6))
    for yy in (cy, top):
        ax.add_patch(Ellipse((cx,yy), 2*rx, 2*ry, facecolor=_light(c,0.82) if yy==cy else "white",
                     edgecolor=c, lw=2.2, zorder=7))

def ic_chip(ax, cx, cy, s, c=TEAL):
    b=s*0.56
    for i in (-1,0,1):
        for dx in (-1,1):
            ax.plot([cx+dx*(b/2),cx+dx*(b/2+s*0.13)],[cy+i*b*0.3,cy+i*b*0.3], color=c, lw=2.0, zorder=5)
            ax.plot([cx+i*b*0.3,cx+i*b*0.3],[cy+dx*(b/2),cy+dx*(b/2+s*0.13)], color=c, lw=2.0, zorder=5)
    ax.add_patch(FancyBboxPatch((cx-b/2,cy-b/2), b, b,
                 boxstyle="round,pad=0,rounding_size=%f"%(s*0.05),
                 facecolor=_light(c,0.82), edgecolor=c, lw=2.2, zorder=6))
    ax.add_patch(Rectangle((cx-b*0.2,cy-b*0.2), b*0.4, b*0.4, facecolor="none",
                 edgecolor=c, lw=1.8, zorder=7))

# ---------- иконки методов ----------
def m_search(ax, cx, cy, s, c=TEAL):
    ax.add_patch(Circle((cx-s*0.08,cy+s*0.08), s*0.26, facecolor="none", edgecolor=c, lw=2.4, zorder=6))
    ax.plot([cx+s*0.12,cx+s*0.34],[cy-s*0.12,cy-s*0.34], color=c, lw=2.8, solid_capstyle="round", zorder=6)

def m_modules(ax, cx, cy, s, c=TEAL):
    d=s*0.17; g=s*0.07
    for ix in (-1,1):
        for iy in (-1,1):
            ax.add_patch(FancyBboxPatch((cx+ix*(g)+(-(d) if ix<0 else 0), cy+iy*(g)+(-(d) if iy<0 else 0)),
                         d, d, boxstyle="round,pad=0,rounding_size=%f"%(s*0.04),
                         facecolor=_light(c,0.55), edgecolor=c, lw=1.6, zorder=6))

def m_hyst(ax, cx, cy, s, c=TEAL):
    ax.plot([cx-s*0.34,cx+s*0.34],[cy+s*0.16,cy+s*0.16], color=_light(c,0.4), lw=1.4, ls=(0,(3,2)), zorder=5)
    ax.plot([cx-s*0.34,cx+s*0.34],[cy-s*0.16,cy-s*0.16], color=_light(c,0.4), lw=1.4, ls=(0,(3,2)), zorder=5)
    ax.plot([cx-s*0.34,cx-s*0.05,cx-s*0.05,cx+s*0.34],
            [cy-s*0.16,cy-s*0.16,cy+s*0.16,cy+s*0.16], color=c, lw=2.6,
            solid_capstyle="round", solid_joinstyle="round", zorder=6)

def m_flask(ax, cx, cy, s, c=TEAL):
    pts=[(cx-s*0.1,cy+s*0.32),(cx-s*0.1,cy+s*0.05),(cx-s*0.3,cy-s*0.32),
         (cx+s*0.3,cy-s*0.32),(cx+s*0.1,cy+s*0.05),(cx+s*0.1,cy+s*0.32)]
    ax.add_patch(Polygon(pts, closed=True, facecolor=_light(c,0.78), edgecolor=c, lw=2.2, zorder=6))
    ax.plot([cx-s*0.16,cx+s*0.16],[cy+s*0.32,cy+s*0.32], color=c, lw=2.6, solid_capstyle="round", zorder=7)

# ===================== фигура =====================
fig,ax=plt.subplots(figsize=(12.3,4.85)); ax.set_xlim(0,12.3); ax.set_ylim(0,4.85); ax.axis("off")

# разделитель колонок
ax.plot([5.75,5.75],[0.15,4.45], color=BORD, lw=1.4, zorder=1)

# ---- левая колонка: Методы ----
ax.text(0.25,4.5,"Методы", fontsize=16, fontweight="bold", color=TEAL, va="center")
methods=[(m_search,"Системный анализ и классификация","обзор предметной области"),
         (m_modules,"Модульное проектирование","архитектуры системы"),
         (m_hyst,"Гистерезис зон сигнала","и аппарат конечных автоматов"),
         (m_flask,"Имитационное моделирование","и натурные измерения")]
ys=[3.65,2.7,1.75,0.8]
for (icon,t1,t2),yy in zip(methods,ys):
    ax.add_patch(Circle((0.62,yy), 0.36, facecolor=_light(TEAL,0.88), edgecolor=_light(TEAL,0.5), lw=1.2, zorder=4))
    icon(ax,0.62,yy,0.7,TEAL)
    ax.text(1.2,yy+0.16,t1, fontsize=12.5, fontweight="bold", color=NAVY, va="center")
    ax.text(1.2,yy-0.19,t2, fontsize=11, color=MUTED, va="center")

# ---- правая колонка: Технологии ----
ax.text(6.0,4.5,"Технологии и инструменты", fontsize=16, fontweight="bold", color=TEAL, va="center")
LX=5.95; RX=12.2
def card(yc):
    ax.add_patch(FancyBboxPatch((LX,yc-0.36), RX-LX, 0.72,
                 boxstyle="round,pad=0,rounding_size=0.1",
                 facecolor=CARD, edgecolor=BORD, lw=1.2, zorder=2))
def logo_box(xc,yc):
    ax.add_patch(FancyBboxPatch((xc-0.34,yc-0.34),0.68,0.68,
                 boxstyle="round,pad=0,rounding_size=0.12",
                 facecolor="white", edgecolor=BORD, lw=1.0, zorder=3))

cards_y=[3.65,2.70,1.75,0.80]   # 4 карточки, выровнены с «Методами» слева
# 1 Платформа: Flutter + Android
card(cards_y[0])
logo_box(6.35,cards_y[0]); flutter(ax,6.35,cards_y[0],0.52)
logo_box(7.12,cards_y[0]); android(ax,7.12,cards_y[0]+0.02,0.52)
ax.text(7.75,cards_y[0]+0.16,"Платформа", fontsize=12.5, fontweight="bold", color=NAVY, va="center")
ax.text(7.75,cards_y[0]-0.18,"Flutter · Dart · Android", fontsize=11, color=INK, va="center")
# 2 BLE
card(cards_y[1]); logo_box(6.35,cards_y[1]); bluetooth(ax,6.35,cards_y[1],0.5)
ax.text(6.95,cards_y[1]+0.16,"BLE-радио", fontsize=12.5, fontweight="bold", color=NAVY, va="center")
ax.text(6.95,cards_y[1]-0.18,"flutter_blue_plus · flutter_ble_peripheral", fontsize=10.5, color=INK, va="center")
# 3 Данные/доступы
card(cards_y[2]); logo_box(6.35,cards_y[2]); ic_db(ax,6.35,cards_y[2],0.6,TEAL)
ax.text(6.95,cards_y[2]+0.16,"Данные · доступы", fontsize=12.5, fontweight="bold", color=NAVY, va="center")
ax.text(6.95,cards_y[2]-0.18,"shared_preferences · permission_handler", fontsize=10.5, color=INK, va="center")
# 4 Канал управления
card(cards_y[3]); logo_box(6.35,cards_y[3]); ic_chip(ax,6.35,cards_y[3],0.6,TEAL)
ax.text(6.95,cards_y[3]+0.16,"Канал управления", fontsize=12.5, fontweight="bold", color=NAVY, va="center")
ax.text(6.95,cards_y[3]-0.18,"HM-10: BLE → RS-485 · Ethernet → RS-485", fontsize=10.5, color=INK, va="center")

fig.savefig(os.path.join(OUT,"fig_slide5.png"), dpi=200, facecolor="white", bbox_inches="tight", pad_inches=0.08)
plt.close(); print("OK slide5 fig")
