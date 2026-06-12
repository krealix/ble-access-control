import 'package:flutter_test/flutter_test.dart';
import 'package:ble_beacon_app/models/gateway.dart';

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

    test('JSON round-trip сохраняет stownId', () {
      final v = AuthorizedVehicle(name: 'Авто', stownId: 'A1B2C3D4E5F601');
      final back = AuthorizedVehicle.fromJson(v.toJson());
      expect(back.stownId, 'A1B2C3D4E5F601');
      expect(back.matches(advStownId: 'A1B2C3D4E5F601'), isTrue);
    });
  });
}
