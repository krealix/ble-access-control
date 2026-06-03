// Виртуальная база замков и авторизованных устройств — тест логики без железа.
//
// Имитирует то, что делает контроллер за HM10 (RS-485 «нижний блок»):
// разбирает 10-байтовый пакет, проверяет наличие замка и авторизацию устройства,
// возвращает «ответ» (как пришёл бы по notify с FFE1).

import 'package:shared_preferences/shared_preferences.dart';

class LockResult {
  final bool ok;
  final String message;
  final List<int> reply; // имитация ответа контроллера (RX)
  const LockResult(this.ok, this.message, this.reply);
}

class VirtualLockDb {
  /// Известные замки (таблица контроллера). Нет в базе → ошибка.
  final Set<int> locks;

  /// Авторизованные идентификаторы (7-байтовые токены в hex, нижний регистр).
  /// Пустой набор = проверка авторизации выключена.
  final Set<String> authorized;

  VirtualLockDb({Set<int>? locks, Set<String>? authorized})
      : locks = locks ?? {0x7702, 0x7703},
        authorized = authorized ?? <String>{};

  static const _kLocks = 'vdb_locks';
  static const _kAuth = 'vdb_authorized';

  /// Загружает базу из хранилища (по умолчанию — замки 7702/7703, без авторизаций).
  static Future<VirtualLockDb> load() async {
    final p = await SharedPreferences.getInstance();
    final lockStrs = p.getStringList(_kLocks);
    final auth = p.getStringList(_kAuth);
    return VirtualLockDb(
      locks: lockStrs?.map((s) => int.parse(s, radix: 16)).toSet(),
      authorized: auth?.toSet(),
    );
  }

  /// Сохраняет текущую базу.
  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(
        _kLocks, locks.map((l) => l.toRadixString(16)).toList());
    await p.setStringList(_kAuth, authorized.toList());
  }

  static String _h2(int b) => b.toRadixString(16).padLeft(2, '0');
  static String hex4(int v) => v.toRadixString(16).padLeft(4, '0').toUpperCase();

  /// Обрабатывает 10-байтовый пакет так же, как это сделал бы контроллер.
  LockResult handle(List<int> packet) {
    if (packet.length != 10) {
      return const LockResult(false, 'пакет должен быть 10 байт', [0xEE]);
    }
    final identHex = packet.sublist(1, 8).map(_h2).join();
    final lockId = (packet[8] << 8) | packet[9];

    if (!locks.contains(lockId)) {
      return LockResult(
        false,
        'замка ${hex4(lockId)} нет в базе',
        [0xEE, packet[8], packet[9]],
      );
    }
    if (authorized.isNotEmpty && !authorized.contains(identHex)) {
      return LockResult(
        false,
        'устройство $identHex не авторизовано',
        [0xEE, packet[8], packet[9]],
      );
    }
    return LockResult(
      true,
      'замок ${hex4(lockId)} открыт',
      [0xAA, packet[8], packet[9]],
    );
  }
}
