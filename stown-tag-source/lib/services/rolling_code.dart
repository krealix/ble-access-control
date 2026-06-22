import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Динамический («rolling») идентификатор метки против клонирования.
///
/// id(7 байт) = первые 7 байт HMAC-SHA256(secret, step),
/// где step = floor(unix_seconds / period). Значение меняется каждые [period]
/// секунд, поэтому перехваченный из эфира код быстро устаревает. Шлюз, зная
/// секрет, сверяет принятый код с ожидаемыми на step-1 / step / step+1
/// (запас на расхождение часов).
class RollingCode {
  RollingCode._();

  /// Период смены кода, секунды.
  static const int periodSeconds = 30;

  /// Длина секрета по умолчанию, байт.
  static const int secretLen = 16;

  /// Случайный секрет как hex-строка (для кнопки «сгенерировать»).
  static String generateSecretHex() {
    final rng = Random.secure();
    final bytes = List<int>.generate(secretLen, (_) => rng.nextInt(256));
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
  }

  /// hex-строка секрета → байты (пустой список при ошибке/пустоте).
  static List<int> parseSecret(String hex) {
    final clean = hex.replaceAll(RegExp('[^0-9a-fA-F]'), '');
    if (clean.length < 2) return const [];
    final out = <int>[];
    for (var i = 0; i + 1 < clean.length; i += 2) {
      out.add(int.parse(clean.substring(i, i + 2), radix: 16));
    }
    return out;
  }

  static Uint8List _stepBytes(int step) {
    final b = Uint8List(8);
    var v = step;
    for (var i = 7; i >= 0; i--) {
      b[i] = v & 0xFF;
      v >>= 8;
    }
    return b;
  }

  /// 7-байтный код для секрета и времени (со смещением шага [stepOffset]).
  static Uint8List code(List<int> secret, {DateTime? at, int stepOffset = 0}) {
    final secs = (at ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    final step = secs ~/ periodSeconds + stepOffset;
    final mac = Hmac(sha256, secret).convert(_stepBytes(step)).bytes;
    return Uint8List.fromList(mac.sublist(0, 7));
  }

  /// hex текущего кода (для показа в UI).
  static String codeHex(List<int> secret, {DateTime? at, int stepOffset = 0}) =>
      code(secret, at: at, stepOffset: stepOffset)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join()
          .toUpperCase();

  /// Совпадает ли принятый из эфира id (hex 7 байт) с кодом секрета на
  /// текущем шаге (±1 шаг на расхождение часов).
  static bool matches(String secretHex, String advIdHex) {
    final secret = parseSecret(secretHex);
    if (secret.isEmpty) return false;
    final adv = advIdHex.toUpperCase();
    for (final off in const [0, -1, 1]) {
      if (codeHex(secret, stepOffset: off) == adv) return true;
    }
    return false;
  }
}
