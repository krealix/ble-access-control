# -*- coding: utf-8 -*-
"""Единая архитектура с двумя каналами доступа (BLE + звонок) в стиле рис. 2.1."""
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Ellipse, FancyArrowPatch, FancyBboxPatch, Arc, Rectangle
import matplotlib.font_manager as fm
for fam in ("Calibri", "Segoe UI", "DejaVu Sans"):
    try:
        fm.findfont(fam, fallback_to_default=False); plt.rcParams["font.family"] = fam; break
    except Exception:
        continue
plt.rcParams["axes.unicode_minus"] = False
OUT = os.path.join(r"C:\Users\krealix\Desktop\Новая папка (3)", "_assets")

PURPLE, BLUE, DEEPBLUE, ORANGE, GREEN = "#7C4DFF","#2D8CFF","#1E66C7","#E07B39","#1FA855"
TEAL, TEAL_D = "#0E9AA7", "#0E7C86"
INK, MUTED, RAIL = "#2B3440","#5B6573","#8A94A3"

def _lighten(hexc, t):
    h=hexc.lstrip("#"); r,g,b=(int(h[i:i+2],16) for i in (0,2,4))
    return "#%02X%02X%02X"%(int(r+(255-r)*t),int(g+(255-g)*t),int(b+(255-b)*t))

def _stage(ax,x,y,w,h,title,sub,color):
    cx=x+w/2
    ax.add_patch(FancyBboxPatch((x+0.045,y-0.06),w,h,boxstyle="round,pad=0.02,rounding_size=0.16",
                 linewidth=0,facecolor="#0B1F33",alpha=0.08,zorder=2))
    ax.add_patch(FancyBboxPatch((x,y),w,h,boxstyle="round,pad=0.02,rounding_size=0.16",
                 linewidth=2.4,edgecolor=color,facecolor=_lighten(color,0.95),zorder=3))
    ax.add_patch(Ellipse((cx,y+h*0.85),0.42,0.42,facecolor=color,edgecolor="white",linewidth=1.6,zorder=4))
    ax.text(cx,y+h*0.85,title[0],ha="center",va="center",fontsize=13,fontweight="bold",color="white",zorder=5)
    ax.text(cx,y+h*0.55,title,ha="center",va="center",fontsize=12,fontweight="bold",color="#111418",zorder=5)
    ax.text(cx,y+h*0.225,sub,ha="center",va="center",fontsize=10.5,color="#111418",zorder=5,linespacing=1.25)

def _flow(ax,x1,y1,x2,y2,label="",lp=None):
    ax.add_patch(FancyArrowPatch((x1,y1),(x2,y2),arrowstyle="-|>",mutation_scale=15,lw=1.8,
                 color=RAIL,zorder=3,shrinkA=0,shrinkB=0))
    if label:
        px,py=lp if lp else ((x1+x2)/2,(y1+y2)/2)
        ax.text(px,py,label,ha="center",va="center",fontsize=10.5,color=INK,zorder=6,linespacing=1.1,
                bbox=dict(boxstyle="round,pad=0.28",fc="white",ec="#D6DBE3",lw=0.9))

def _db(ax,cx,cy,w,h,title,color):
    rx,ey,fill=w/2,0.14,_lighten(color,0.9)
    ax.add_patch(Ellipse((cx,cy-h/2),w,ey*2,facecolor=fill,edgecolor="none",zorder=2))
    ax.add_patch(Rectangle((cx-rx,cy-h/2),w,h,facecolor=fill,edgecolor="none",zorder=3))
    ax.plot([cx-rx,cx-rx],[cy-h/2,cy+h/2],color=color,lw=1.8,zorder=4)
    ax.plot([cx+rx,cx+rx],[cy-h/2,cy+h/2],color=color,lw=1.8,zorder=4)
    ax.add_patch(Arc((cx,cy-h/2),w,ey*2,theta1=180,theta2=360,edgecolor=color,lw=1.8,zorder=4))
    ax.add_patch(Ellipse((cx,cy+h/2),w,ey*2,facecolor=_lighten(color,0.78),edgecolor=color,lw=1.8,zorder=5))
    ax.text(cx,cy,title,ha="center",va="center",fontsize=12,fontweight="bold",color=color,zorder=6,linespacing=1.2)

def _group(ax,x,y,w,h,label):
    ax.add_patch(FancyBboxPatch((x,y),w,h,boxstyle="round,pad=0.02,rounding_size=0.05",linewidth=1.3,
                 edgecolor="#B4BCC8",facecolor="none",linestyle=(0,(6,4)),zorder=1))
    ax.text(x+0.2,y+h," "+label+" ",ha="left",va="center",fontsize=11.5,color="#717A87",style="italic",
            zorder=2,bbox=dict(boxstyle="round,pad=0.2",fc="white",ec="none"))

fig,ax=plt.subplots(figsize=(11.7,6.6)); ax.set_xlim(0,11.7); ax.set_ylim(0,6.6); ax.axis("off")
W,Hs,Hm=1.7,1.5,1.85
col0,col1,col2,col3,col4=0.15,2.35,4.70,6.95,9.05
yT,yB=3.78,0.75
cT,cB=yT+Hs/2,yB+Hs/2
yM=(cT+cB)/2-Hm/2; cM=yM+Hm/2

# группы каналов
_group(ax,-0.05,3.58,4.25,2.06,"Канал BLE · анализ траектории")
_group(ax,-0.05,0.55,4.25,2.06,"Канал по звонку · резерв / гость")
_group(ax,6.74,1.80,4.62,2.52,"Исполнительная часть")

# база авторизованных над анализатором
cxA=col2+W/2
_db(ax,cxA,5.62,1.8,0.86,"База\nавторизованных",ORANGE)
_flow(ax,cxA,5.19,cxA,yM+Hm)

# два канала работают параллельно
ax.annotate("",xy=(2.1,3.50),xytext=(2.1,2.66),
            arrowprops=dict(arrowstyle="<|-|>",linestyle=(0,(4,2.5)),color="#9AA3AE",lw=1.5,
                            shrinkA=0,shrinkB=0))
ax.text(2.1,3.08,"параллельно",fontsize=10,style="italic",color="#5B6573",ha="center",va="center",
        bbox=dict(boxstyle="round,pad=0.22",fc="white",ec="none"),zorder=7)

# каналы (входы)
_stage(ax,col0,yT,W,Hs,"BLE-метка","источник\nрекламы",PURPLE)
_stage(ax,col1,yT,W,Hs,"Сканер","приём\nRSSI(t)",BLUE)
_stage(ax,col0,yB,W,Hs,"Телефон","входящий\nзвонок",TEAL)
_stage(ax,col1,yB,W,Hs,"Приём звонка","caller ID,\nсверка номеров",TEAL_D)
# ядро и исполнение
_stage(ax,col2,yM,W,Hm,"Анализатор","решение\nо доступе",DEEPBLUE)
_stage(ax,col3,yM,W,Hm,"Исполнитель","HM10:\nBLE → RS-485",ORANGE)
_stage(ax,col4,yM,W,Hm,"Замок","электро-\nзамок",GREEN)

# потоки
_flow(ax,col0+W,cT,col1,cT,"BLE-реклама")
_flow(ax,col0+W,cB,col1,cB,"звонок")
_flow(ax,col1+W,cT,col2+0.02,cM+0.55,"RSSI(t)",lp=(4.32,3.95))
_flow(ax,col1+W,cB,col2+0.02,cM-0.55,"номер\n(BCD)",lp=(4.32,2.05))
_flow(ax,col2+W,cM,col3,cM,"команда 10 Б")
_flow(ax,col3+W,cM,col4,cM,"RS-485")

fig.tight_layout()
fig.savefig(os.path.join(OUT,"fig_arch_dual.png"),dpi=200,facecolor="white")
plt.close()
print("OK arch dual")
