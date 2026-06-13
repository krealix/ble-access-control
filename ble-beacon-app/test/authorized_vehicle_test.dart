import 'package:flutter_test/flutter_test.dart';
import 'package:ble_beacon_app/models/gateway.dart';
import 'package:ble_beacon_app/services/incoming_call.dart';

void main() {
  group('AuthorizedVehicle сверка по STOWN ID', () {
    test('совпадение по ID', () {
      final v = AuthorizedVehicle(name: 'Авто', stownId: 'A1B2C3D4E5F601');
      expect(v.isValid, isTrue);
      expect(v.matches(advStownId: 'A1B2C3D4E5F601'), isTrue);
    });

    test('нормализация: регистр и разделители игнорируются', () {
      final v = AuthorizedVehicle(name: 'Авто', stownId: 'a1:b2:c3:d4:e5:f6:01');
      expect(v.matches(advStownId: 'A1B2C3D4E5F601'), isTrue);
    });

    test('чужой ID не совпадает', () {
      final v = AuthorizedVehicle(name: 'Авто', stownId: 'A1B2C3D4E5F601');
      expect(v.matches(advStownId: '0000000000FFFF'), isFalse);
    });

    test('ID задан, но в рекламе его нет — не совпадает', () {
      final v = AuthorizedVehicle(name: 'Авто', stownId: 'A1B2C3D4E5F601');
      expect(v.matches(advUuid: 'DEADBEEF', advStownId: null), isFalse);
    });

    test('explainMatch отмечает поле ID', () {
      final v = AuthorizedVehicle(name: 'Авто', stownId: 'A1B2C3D4E5F601');
      expect(v.explainMatch(advStownId: 'A1B2C3D4E5F601'), contains('ID'));
    });

    test('другие поля (Major) продолжают работать', () {
      final v = AuthorizedVehicle(name: 'Авто', major: 7);
      expect(v.matches(advMajor: 7), isTrue);
      expect(v.matches(advMajor: 8), isFalse);
    });

    test('сверка по matchKey (STOWN:имя и MAC)', () {
      final stown = AuthorizedVehicle(name: 'Авто', matchKey: 'STOWN:Пропуск');
      expect(stown.isValid, isTrue);
      expect(stown.matches(advKey: 'STOWN:Пропуск'), isTrue);
      expect(stown.matches(advKey: 'STOWN:Чужой'), isFalse);

      final byMac = AuthorizedVehicle(name: 'Авто', matchKey: 'C0:1A:22:33:44:55');
      expect(byMac.matches(advKey: 'c0:1a:22:33:44:55'), isTrue); // регистр не важен
      expect(byMac.matches(advKey: 'FF:FF:FF:FF:FF:FF'), isFalse);
    });

    test('доступ по звонку: нормализация номера и PHONE-ключ', () {
      // +7 и 8 приводятся к одним последним 10 цифрам
      expect(normalizePhone('+7 (999) 123-45-67'), '9991234567');
      expect(normalizePhone('89991234567'), '9991234567');
      final v = AuthorizedVehicle(name: 'Авто', matchKey: 'PHONE:9991234567');
      expect(v.matches(advKey: 'PHONE:9991234567'), isTrue);
      expect(v.matches(advKey: 'PHONE:0000000000'), isFalse);
      expect(v.explainMatch(advKey: 'PHONE:9991234567'), contains('Телефон'));
    });

    test('matchKey переживает JSON round-trip', () {
      final v = AuthorizedVehicle(name: 'Авто', matchKey: 'STOWN:Пропуск');
      final back = AuthorizedVehicle.fromJson(v.toJson());
      expect(back.matchKey, 'STOWN:Пропуск');
      expect(back.matches(advKey: 'STOWN:Пропуск'), isTrue);
    });

    test('JSON round-trip сохраняет stownId', () {
      final v = AuthorizedVehicle(name: 'Авто', stownId: 'A1B2C3D4E5F601');
      final back = AuthorizedVehicle.fromJson(v.toJson());
      expect(back.stownId, 'A1B2C3D4E5F601');
      expect(back.matches(advStownId: 'A1B2C3D4E5F601'), isTrue);
    });
  });
}
