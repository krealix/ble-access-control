// Редактор виртуальной базы: замки и авторизованные ID. Изменения сохраняются.

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'virtual_lock_db.dart';

class LockDbPage extends StatefulWidget {
  final VirtualLockDb db;
  const LockDbPage(this.db, {super.key});

  @override
  State<LockDbPage> createState() => _LockDbPageState();
}

class _LockDbPageState extends State<LockDbPage> {
  final _lock = TextEditingController();
  final _token = TextEditingController();

  VirtualLockDb get db => widget.db;

  @override
  void dispose() {
    _lock.dispose();
    _token.dispose();
    super.dispose();
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _addLock() async {
    final t = _lock.text.trim().replaceAll('0x', '').replaceAll(' ', '');
    final v = int.tryParse(t, radix: 16);
    if (v == null || v < 0 || v > 0xFFFF) {
      _snack('Замок: hex 0000..FFFF');
      return;
    }
    setState(() => db.locks.add(v));
    _lock.clear();
    await db.save();
  }

  Future<void> _removeLock(int v) async {
    setState(() => db.locks.remove(v));
    await db.save();
  }

  Future<void> _addToken() async {
    final t = _token.text
        .trim()
        .replaceAll(RegExp(r'[:\-\s]'), '')
        .toLowerCase();
    if (t.isEmpty ||
        t.length > 14 ||
        t.length.isOdd ||
        int.tryParse(t, radix: 16) == null) {
      _snack('ID: hex, до 7 байт (макс. 14 символов)');
      return;
    }
    // В пакете идентификатор всегда 7 байт (хвост — нули), поэтому дополняем.
    final norm = t.padRight(14, '0');
    setState(() => db.authorized.add(norm));
    _token.clear();
    await db.save();
  }

  Future<void> _removeToken(String s) async {
    setState(() => db.authorized.remove(s));
    await db.save();
  }

  @override
  Widget build(BuildContext context) {
    final locks = db.locks.toList()..sort();
    final tokens = db.authorized.toList()..sort();

    return Scaffold(
      appBar: AppBar(title: const Text('Виртуальная база')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section('ЗАМКИ В БАЗЕ'),
          _addRow(
            controller: _lock,
            hint: 'номер замка hex, напр. 7704',
            onAdd: _addLock,
          ),
          const SizedBox(height: 8),
          if (locks.isEmpty)
            _empty('Замков нет — любая отправка вернёт ошибку')
          else
            ...locks.map((v) => _chipRow(
                  VirtualLockDb.hex4(v),
                  () => _removeLock(v),
                )),
          const SizedBox(height: 24),
          _section('АВТОРИЗОВАННЫЕ ID (токены 7 байт)'),
          _addRow(
            controller: _token,
            hint: 'hex до 14 символов',
            onAdd: _addToken,
          ),
          const SizedBox(height: 8),
          if (tokens.isEmpty)
            _empty('Список пуст — авторизация выключена (пускает любой ID)')
          else
            ...tokens.map((s) => _chipRow(s, () => _removeToken(s))),
        ],
      ),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(t,
            style: const TextStyle(
                color: kMuted, fontSize: 12, fontWeight: FontWeight.bold)),
      );

  Widget _empty(String t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(t, style: const TextStyle(color: kMuted, fontSize: 12)),
      );

  Widget _addRow({
    required TextEditingController controller,
    required String hint,
    required VoidCallback onAdd,
  }) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            style: const TextStyle(fontFamily: 'monospace', color: kOnSurface),
            decoration: InputDecoration(hintText: hint),
            onSubmitted: (_) => onAdd(),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: onAdd,
          style: FilledButton.styleFrom(
            minimumSize: const Size(56, 52),
            backgroundColor: kPrimary,
          ),
          child: const Icon(Icons.add),
        ),
      ],
    );
  }

  Widget _chipRow(String text, VoidCallback onRemove) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.only(left: 14, right: 4),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDivider),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 14,
                    color: kOnSurface)),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: kDanger),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
