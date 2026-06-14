import 'dart:math';

/// Одномерный фильтр Калмана для сглаживания RSSI.
///
/// q — шум процесса (больше → отзывчивее), r — шум измерения (больше → глаже).
/// При q=0.5, r=6.0 установившийся коэффициент усиления ≈ 0.25 (близко к EMA
/// α≈0.25): фильтр гасит выбросы, но успевает отслеживать приближение метки.
class Kalman1D {
  Kalman1D({this.q = 0.5, this.r = 6.0});
  final double q; // шум процесса
  final double r; // шум измерения
  double? _x;
  double _p = 1.0;

  double update(double z) {
    if (_x == null) {
      _x = z;
      return z;
    }
    _p += q;
    final k = _p / (_p + r);
    _x = _x! + k * (z - _x!);
    _p = (1 - k) * _p;
    return _x!;
  }
}

/// Состояние доступа по траектории.
enum Access { far, approaching, granted, leaving }

class TrajSample {
  TrajSample({
    required this.state,
    required this.distance,
    required this.trend,
    required this.rssi,
    required this.justGranted,
  });
  final Access state;
  final double distance; // оценка дистанции, м
  final double trend; // наклон RSSI, dBm/с (>0 — приближается)
  final double rssi; // сглаженный RSSI
  final bool justGranted; // момент выдачи доступа (фронт)
}

/// Анализатор траектории: Калман → лог-дистанция → тренд (МНК) → КА доступа.
/// Ядро ВКР: решение принимается не по мгновенному порогу, а по устойчивому
/// приближению метки.
class TrajectoryAnalyzer {
  TrajectoryAnalyzer({
    this.grantDistance = 2.0, // радиус зоны доступа, м
    this.approachSamples = 4, // сколько подряд «приближается» до доступа
    this.trendEps = 0.2, // порог наклона RSSI, dBm/с
    this.txPower = -59.0, // калиброванный RSSI на 1 м
    this.n = 2.5, // показатель затухания среды
  });

  final double grantDistance;
  final int approachSamples;
  final double trendEps;
  final double txPower;
  final double n;

  final Kalman1D _k = Kalman1D();
  final List<double> _t = [];
  final List<double> _r = [];
  static const int _window = 6;

  bool _granted = false;
  int _approach = 0;
  // Защёлка «было устойчивое приближение»: ставится после approachSamples
  // подряд приближающихся проб, снимается только при перевзводе (отдалении).
  // Так доступ выдаётся, даже если у самой зоны сигнал кратко выровнялся
  // (из-за лага сглаживания), но НЕ выдаётся метке, появившейся уже рядом.
  bool _approached = false;

  double _distance(double rssi) =>
      pow(10, (txPower - rssi) / (10 * n)).toDouble();

  double _slope() {
    final m = _t.length;
    if (m < 2) return 0;
    final t0 = _t.first;
    double sx = 0, sy = 0, sxx = 0, sxy = 0;
    for (var i = 0; i < m; i++) {
      final x = _t[i] - t0;
      final y = _r[i];
      sx += x;
      sy += y;
      sxx += x * x;
      sxy += x * y;
    }
    final d = m * sxx - sx * sx;
    if (d == 0) return 0;
    return (m * sxy - sx * sy) / d;
  }

  TrajSample push(double tSec, double rssiRaw) {
    final rssi = _k.update(rssiRaw);
    _t.add(tSec);
    _r.add(rssi);
    if (_t.length > _window) {
      _t.removeAt(0);
      _r.removeAt(0);
    }
    final trend = _slope();
    final dist = _distance(rssi);

    if (trend > trendEps) {
      _approach++;
      if (_approach >= approachSamples) _approached = true;
    } else if (trend < -trendEps) {
      // Явное отдаление сбрасывает счётчик приближения. На «штиле»
      // (|trend| ≤ eps) счётчик и защёлку держим — сигнал у зоны может ровняться.
      _approach = 0;
    }

    var justGranted = false;
    Access state;
    if (!_granted) {
      if (dist <= grantDistance && _approached) {
        _granted = true;
        justGranted = true;
        state = Access.granted;
      } else {
        state = trend > trendEps ? Access.approaching : Access.far;
      }
    } else {
      // Уже выдан: перевзвод только при явном отдалении (гистерезис 1.6×).
      if (dist > grantDistance * 1.6) {
        _granted = false;
        _approached = false;
        _approach = 0;
        state = Access.far;
      } else {
        state = trend < -trendEps ? Access.leaving : Access.granted;
      }
    }
    return TrajSample(
      state: state,
      distance: dist,
      trend: trend,
      rssi: rssi,
      justGranted: justGranted,
    );
  }
}
