import 'package:flutter_test/flutter_test.dart';
import 'package:ble_beacon_app/services/trajectory.dart';

void main() {
  group('Kalman1D', () {
    test('первое измерение возвращается как есть, затем сглаживает', () {
      final k = Kalman1D();
      expect(k.update(-70), -70);
      // Резкий выброс не перетягивает оценку целиком.
      final after = k.update(-40);
      expect(after, greaterThan(-70));
      expect(after, lessThan(-40));
    });
  });

  group('TrajectoryAnalyzer', () {
    test('устойчивое приближение выдаёт доступ один раз (фронт)', () {
      final a = TrajectoryAnalyzer(
        grantDistance: 2.0,
        approachSamples: 4,
        trendEps: 0.2,
      );
      // RSSI растёт (метка приближается) до ~1 м и удерживается рядом.
      final seq = [
        -90, -86, -82, -78, -74, -70, -66, -62, -58, -54, -52, //
        -52, -52, -52, -52, -52
      ];
      var grants = 0;
      var t = 0.0;
      for (final r in seq) {
        final s = a.push(t, r.toDouble());
        if (s.justGranted) grants++;
        t += 0.5;
      }
      expect(grants, 1, reason: 'доступ должен сработать ровно один раз');
    });

    test('стабильно далёкая метка доступ не получает', () {
      final a = TrajectoryAnalyzer(grantDistance: 2.0);
      var grants = 0;
      var t = 0.0;
      for (var i = 0; i < 12; i++) {
        final s = a.push(t, -92.0); // далеко и без приближения
        if (s.justGranted) grants++;
        t += 0.5;
      }
      expect(grants, 0);
    });

    test('после отдаления КА перевзводится и может выдать снова', () {
      final a = TrajectoryAnalyzer(
        grantDistance: 2.0,
        approachSamples: 4,
        trendEps: 0.2,
      );
      var t = 0.0;
      var grants = 0;
      void feed(List<int> seq) {
        for (final r in seq) {
          final s = a.push(t, r.toDouble());
          if (s.justGranted) grants++;
          t += 0.5;
        }
      }

      // подъезд → доступ
      feed([-90, -86, -82, -78, -74, -70, -66, -62, -58, -54, -52, -52]);
      // отъезд → перевзвод (смягчённая дистанция уходит за гистерезис)
      feed([-58, -66, -74, -82, -90, -95, -95, -95, -95, -95]);
      // снова подъезд → доступ
      feed([-90, -86, -82, -78, -74, -70, -66, -62, -58, -54, -52, -52]);
      expect(grants, 2);
    });
  });
}
