import 'package:flutter_test/flutter_test.dart';
import 'package:ble_beacon_app/services/rolling_code.dart';

void main() {
  group('RollingCode', () {
    test('код детерминирован для секрета и времени, 7 байт', () {
      final secret = RollingCode.parseSecret('00112233445566778899AABBCCDDEEFF');
      final at = DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000);
      final a = RollingCode.codeHex(secret, at: at);
      final b = RollingCode.codeHex(secret, at: at);
      expect(a, b);
      expect(a.length, 14); // 7 байт hex
    });

    test('соседние шаги дают разные коды', () {
      final secret = RollingCode.parseSecret('00112233445566778899AABBCCDDEEFF');
      final at = DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000);
      expect(RollingCode.codeHex(secret, at: at),
          isNot(RollingCode.codeHex(secret, at: at, stepOffset: 1)));
    });

    test('matches принимает текущий код своего секрета и отвергает чужой', () {
      final s1 = RollingCode.generateSecretHex();
      final code = RollingCode.codeHex(RollingCode.parseSecret(s1));
      expect(RollingCode.matches(s1, code), isTrue);
      final s2 = RollingCode.generateSecretHex();
      expect(RollingCode.matches(s2, code), isFalse);
    });
  });
}
