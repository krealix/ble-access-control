"""Числовой пример работы анализатора для таблицы в главе 2 ВКР."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "ble-scanner"))

from trajectory import TrajectoryAnalyzer, simulate_pass

series = simulate_pass()  # n=60, dt=0.5, 8 м -> 0.5 м -> 8 м, шум 4 дБ, seed=42
an = TrajectoryAnalyzer(grant_distance=2.0, approach_samples=4)
samples = [an.push(t, r) for t, r in series]

# Печатаем каждый 2-й шаг до момента выдачи доступа + момент сброса
granted_at = next((s.t for s in samples if s.state.name == "GRANTED"), None)
reset_at = None
seen_grant = False
for s in samples:
    if s.state.name == "GRANTED":
        seen_grant = True
    elif seen_grant and reset_at is None:
        reset_at = s.t

print("t;rssi_raw;rssi_smooth;dist;trend;streak_state")
streak = 0
eps = an.trend_eps
prev_states = []
streaks = []
st = 0
for s in samples:
    if s.trend > eps:
        st += 1
    elif s.trend < -eps:
        st = 0
    streaks.append(st)

for i, s in enumerate(samples):
    print(f"{s.t:.1f};{s.rssi_raw:.1f};{s.rssi_smooth:.1f};{s.distance:.2f};"
          f"{s.trend:+.2f};{streaks[i]};{s.state.name}")

print()
print("granted_at =", granted_at, " reset_at =", reset_at)
