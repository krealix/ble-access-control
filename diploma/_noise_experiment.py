"""Статистическая оценка устойчивости к шуму: пороговый подход vs траектория.

Статичная метка на 5 м от считывателя, 60 измерений с шагом 0,5 с (30 с).
Для каждого сигма — 200 прогонов; считаем долю прогонов с хотя бы одним
ложным предоставлением доступа и среднее число срабатываний порога.
"""
import math
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "ble-scanner"))

from trajectory import Access, TrajectoryAnalyzer, PATH_LOSS_N, TX_POWER_1M

D_STATIC = 5.0
THRESHOLD = TX_POWER_1M - 10 * PATH_LOSS_N * math.log10(2.0)  # −65 дБм (зона 2 м)
BASE = TX_POWER_1M - 10 * PATH_LOSS_N * math.log10(D_STATIC)
RUNS = 200
N_SAMPLES = 60
DT = 0.5

print(f"base RSSI at {D_STATIC} m = {BASE:.2f} dBm, threshold = {THRESHOLD:.0f} dBm")
print("sigma;threshold_runs_with_fire_%;threshold_avg_fires;trajectory_runs_with_grant_%")
for sigma in (2.0, 4.0, 6.0):
    thr_runs = 0
    thr_total = 0
    traj_runs = 0
    for r in range(RUNS):
        rnd = random.Random(1000 + r)
        an = TrajectoryAnalyzer(grant_distance=2.0, approach_samples=4)
        fires = 0
        granted = False
        for i in range(N_SAMPLES):
            rssi = BASE + rnd.gauss(0.0, sigma)
            if rssi > THRESHOLD:
                fires += 1
            if an.push(i * DT, rssi).state == Access.GRANTED:
                granted = True
        if fires:
            thr_runs += 1
        thr_total += fires
        if granted:
            traj_runs += 1
    print(f"{sigma};{100.0 * thr_runs / RUNS:.1f};{thr_total / RUNS:.2f};"
          f"{100.0 * traj_runs / RUNS:.1f}")
