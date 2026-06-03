import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Стабильный идентификатор устройства (7 байт), хранится между запусками.
///
/// Почему не MAC: на Android приложение не может прочитать свой Bluetooth-MAC
/// (с Android 6+ возвращается 02:00:00:00:00:00) и MAC рандомизируется; на iOS
/// аналогично. Поэтому используем собственный токен. 7 байт = 56 бит — ровно
/// влезает в байты 2–8 пакета (полный 128-битный UUID не влезает).
class DeviceId {
  static const _key = 'hm10_device_token_v1';

  /// Токен в hex (14 символов). Генерируется и сохраняется при первом запуске.
  static Future<String> hex() async {
    final prefs = await SharedPreferences.getInstance();
    var token = prefs.getString(_key);
    if (token == null || token.length != 14) {
      final rnd = Random.secure();
      token = List<int>.generate(7, (_) => rnd.nextInt(256))
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      await prefs.setString(_key, token);
    }
    return token;
  }
}
