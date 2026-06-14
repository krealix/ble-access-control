import 'package:flutter_test/flutter_test.dart';
import 'package:ble_beacon_app/services/scanner_logger.dart';

void main() {
  group('ScannerLogger.distanceFromRssi', () {
    test('на калибровочном RSSI (tx) дистанция ≈ 1 м', () {
      expect(ScannerLogger.distanceFromRssi(-59), closeTo(1.0, 0.01));
    });

    test('на 10·n дБ ниже tx дистанция ≈ 10 м', () {
      // tx=-59, n=2.5 → 10·n=25 дБ; -59-25=-84 → 10 м.
      expect(ScannerLogger.distanceFromRssi(-84), closeTo(10.0, 0.1));
    });

    test('ближе (выше RSSI) → меньше дистанция (монотонность)', () {
      expect(ScannerLogger.distanceFromRssi(-50),
          lessThan(ScannerLogger.distanceFromRssi(-70)));
    });
  });
}
