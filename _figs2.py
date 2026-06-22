# -*- coding: utf-8 -*-
"""Рисунки 3 (канал по звонку) и 4 (пакет STOWN) для презентации ВКР."""
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Polygon, FancyArrowPatch
import matplotlib.font_manager as fm

for fam in ("Calibri", "Segoe UI", "DejaVu Sans"):
    try:
        fm.findfont(fam, fallback_to_default=False); plt.rcParams["font.family"] = fam; break
    except Exception:
        continue
plt.rcParams["axes.unicode_minus"] = False
MONO = "Consolas"
try:
    fm.findfont(MONO, fallback_to_default=False)
except Exception:
    MONO = "DejaVu Sans Mono"

OUT = os.path.join(r"C:\Users\krealix\Desktop\Новая папка (3)", "_assets")
os.makedirs(OUT, exist_ok=True)
NAVY="#0E2A47"; TEAL="#0E9AA7"; TEAL2="#27C2B6"; GREEN="#2BA84A"; RED="#D9534F"
AMBER="#E0A23B"; CARD="#EEF3F8"; MUTED="#5B6B7B"; LINE="#D4DEE8"; INK="#1E2A38"; ORANGE="#E07B39"
def _light(hexc,t):
    h=hexc.lstrip("#"); r,g,b=(int(h[i:i+2],16) for i in (0,2,4))
    return "#%02X%02X%02X"%(int(r+(255-r)*t),int(g+(255-g)*t),int(b+(255-b)*t))

# ======================================================================
# Рисунок 3 — Канал доступа по входящему звонку (GSM)
# ======================================================================
fig,ax=plt.subplots(figsize=(5.0,6.6)); ax.set_xlim(0,10); ax.set_ylim(0,14.6); ax.axis("off")
def term(x,y,txt,w=5.6,h=1.05,fc=_light(NAVY,0.9),ec=NAVY,fs=11.5,tc=NAVY):
    ax.add_patch(FancyBboxPatch((x-w/2,y-h/2),w,h,boxstyle="round,pad=0.02,rounding_size=0.5",
                 lw=1.8,edgecolor=ec,facecolor=fc,zorder=3))
    ax.text(x,y,txt,ha="center",va="center",fontsize=fs,color=tc,fontweight="bold",zorder=4,linespacing=1.25)
def proc(x,y,txt,w=5.8,h=1.1,ec=TEAL,fs=11,tc=INK):
    ax.add_patch(FancyBboxPatch((x-w/2,y-h/2),w,h,boxstyle="round,pad=0.02,rounding_size=0.12",
                 lw=2.0,edgecolor=ec,facecolor=_light(ec,0.9),zorder=3))
    ax.text(x,y,txt,ha="center",va="center",fontsize=fs,color=tc,zorder=4,linespacing=1.22)
def dec(x,y,txt,w=5.4,h=1.7,ec=ORANGE,fs=11):
    pts=[(x,y+h/2),(x+w/2,y),(x,y-h/2),(x-w/2,y)]
    ax.add_patch(Polygon(pts,closed=True,lw=2.0,edgecolor=ec,facecolor=_light(ec,0.9),zorder=3))
    ax.text(x,y,txt,ha="center",va="center",fontsize=fs,color="#7A4A1E",zorder=4,linespacing=1.2)
def arr(p1,p2,label="",lp=None,color=TEAL2):
    ax.add_patch(FancyArrowPatch(p1,p2,arrowstyle="-|>",mutation_scale=15,lw=2.0,color="#7A8493",zorder=2))
    if label:
        px,py=lp if lp else ((p1[0]+p2[0])/2,(p1[1]+p2[1])/2)
        ax.text(px,py,label,fontsize=10.5,fontweight="bold",ha="center",va="center",color="#444",
                bbox=dict(boxstyle="circle,pad=0.22",fc="white",ec="#C9D0DA",lw=1.0),zorder=5)
MX=4.5; RX=8.4
term(MX,13.9,"Входящий вызов\nна телефон-шлюз")
proc(MX,12.25,"Чтение номера\nвызывающего (caller ID)")
proc(MX,10.6,"Автоотклонение вызова\n(без установки соединения)",ec=AMBER)
proc(MX,8.95,"Нормализация номера:\nпоследние 10 цифр")
dec(MX,6.95,"Номер в базе\nавторизованных?")
proc(MX,4.95,"Команда управления:\nномер в BCD (7 байт)",ec=TEAL)
proc(MX,3.3,"Отправка по каналу\nBLE→RS-485 / сеть",ec=TEAL)
term(MX,1.55,"Открытие замка\nи журналирование",fc=_light(GREEN,0.85),ec=GREEN,tc="#1B6B33")
term(RX,6.95,"Игнор\nжурнал",w=2.5,h=1.0,fc=_light(RED,0.9),ec=RED,fs=10,tc="#9B2D2A")
arr((MX,13.37),(MX,12.82)); arr((MX,11.7),(MX,11.17)); arr((MX,10.05),(MX,9.52))
arr((MX,8.4),(MX,7.82)); arr((MX,6.1),(MX,5.52),"да",lp=(MX+0.45,5.85))
arr((MX+2.7,6.95),(RX-1.25,6.95),"нет",lp=(6.7,7.3))
arr((MX,4.4),(MX,3.86)); arr((MX,2.75),(MX,2.1))
fig.tight_layout()
fig.savefig(os.path.join(OUT,"fig_call_channel.png"),dpi=200,facecolor="white")
plt.close()

# ======================================================================
# Рисунок 4 — 10-байтный пакет STOWN + динамический идентификатор
# ======================================================================
fig,ax=plt.subplots(figsize=(7.4,4.9)); ax.set_xlim(0,14.8); ax.set_ylim(0,9.8); ax.axis("off")
# --- байтовая лента пакета ---
x0=0.5; top=8.7; bw=1.32; bh=1.5
def cell(i,fc,ec):
    x=x0+i*bw
    ax.add_patch(FancyBboxPatch((x,top-bh),bw*0.94,bh,boxstyle="round,pad=0.0,rounding_size=0.06",
                 lw=1.8,edgecolor=ec,facecolor=fc,zorder=3))
    return x+bw*0.47
hexvals=["87","00","00","00","00","00","00","00","77","02"]
cols=[NAVY]+[TEAL]*7+[GREEN,GREEN]
for i,(hx,c) in enumerate(zip(hexvals,cols)):
    cx=cell(i,_light(c,0.86),c)
    ax.text(cx,top-bh*0.40,hx,ha="center",va="center",fontsize=14,family=MONO,fontweight="bold",color=c,zorder=4)
    ax.text(cx,top-bh*0.82,str(i),ha="center",va="center",fontsize=8.5,color=MUTED,zorder=4)
# группирующие подписи
def brace(i1,i2,txt,color):
    xa=x0+i1*bw+0.1; xb=x0+i2*bw+bw*0.84
    ax.plot([xa,xa,xb,xb],[top-bh-0.18,top-bh-0.42,top-bh-0.42,top-bh-0.18],color=color,lw=1.6,zorder=3)
    ax.text((xa+xb)/2,top-bh-0.95,txt,ha="center",va="center",fontsize=10.5,color=color,fontweight="bold",zorder=4)
brace(0,0,"Команда\nоткрытия\n0x87 / 0x01",NAVY)
brace(1,7,"Идентификатор носителя — 7 байт (56 бит)",TEAL)
brace(8,9,"Номер замка\nuint16, BE",GREEN)
ax.text(x0,top+0.55,"Команда открытия STOWN — фиксированные 10 байт",
        ha="left",va="center",fontsize=12.5,fontweight="bold",color=NAVY)
# --- режимы идентификатора (чипы) ---
yc=4.45
ax.text(x0,yc+0.75,"Идентификатор носителя:",ha="left",va="center",fontsize=11,fontweight="bold",color=INK)
chips=["Device ID (токен)","MAC","UUID","Телефон / IMEI (BCD)"]
cx=x0
for ch in chips:
    w=0.30+len(ch)*0.158
    ax.add_patch(FancyBboxPatch((cx,yc-0.02),w,0.62,boxstyle="round,pad=0.02,rounding_size=0.18",
                 lw=1.4,edgecolor=TEAL,facecolor=_light(TEAL,0.9),zorder=3))
    ax.text(cx+w/2,yc+0.29,ch,ha="center",va="center",fontsize=9.8,color=NAVY,zorder=4)
    cx+=w+0.28
# --- rolling-code блок ---
ax.add_patch(FancyBboxPatch((x0,0.35),14.0,2.95,boxstyle="round,pad=0.02,rounding_size=0.10",
             lw=1.8,edgecolor=AMBER,facecolor=_light(AMBER,0.92),zorder=2))
ax.text(x0+0.35,2.92,"Динамический идентификатор (rolling-code) — защита от клонирования",
        ha="left",va="center",fontsize=11.5,fontweight="bold",color="#8A5A12",zorder=4)
ax.text(x0+0.35,2.18,"ID = HMAC-SHA256(secret, floor(t / 30 с)) [0…6]",
        ha="left",va="center",fontsize=12,family=MONO,color=NAVY,zorder=4)
ax.text(x0+0.35,1.35,"• код меняется каждые 30 с — перехваченный из эфира быстро устаревает\n"
        "• шлюз, зная секрет, сверяет шаги  t−1 · t · t+1  (запас на расхождение часов)",
        ha="left",va="center",fontsize=9.8,color=INK,zorder=4,linespacing=1.4)
fig.tight_layout()
fig.savefig(os.path.join(OUT,"fig_stown_packet.png"),dpi=200,facecolor="white")
plt.close()
print("OK figs 3,4")
