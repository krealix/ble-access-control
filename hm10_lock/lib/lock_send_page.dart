// Экран: найти HM10 (по MAC), собрать пакет, открыть замок. Тёмная тема STOWN.

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app_theme.dart';
import 'device_id.dart';
import 'hm10_service.dart';
import 'lock_db_page.dart';
import 'virtual_lock_db.dart';

class LockSendPage extends StatefulWidget {
  const LockSendPage({super.key});

  @override
  State<LockSendPage> createState() => _LockSendPageState();
}

class _LockSendPageState extends State<LockSendPage> {
  final _cmd = TextEditingController(text: '87');
  final _lock = TextEditingController(text: '7702');
  final _ident = TextEditingController();

  List<ScanResult> _devices = [];
  BluetoothDevice? _selected;
  final List<String> _log = [];
  bool _busy = false;
  bool _testMode = false;
  VirtualLockDb _db = VirtualLockDb();

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Загружаем сохранённую базу и стабильный ID устройства; ID добавляем в
    // авторизованные (чтобы тест-отправка по умолчанию проходила).
    final db = await VirtualLockDb.load();
    final token = await DeviceId.hex();
    db.authorized.add(token);
    await db.save();
    if (!mounted) return;
    setState(() {
      _db = db;
      _ident.text = token;
    });
    _addLog('ID устройства: $token');
  }

  @override
  void dispose() {
    _cmd.dispose();
    _lock.dispose();
    _ident.dispose();
    super.dispose();
  }

  void _addLog(String s) {
    final ts = TimeOfDay.now().format(context);
    setState(() => _log.insert(0, '$ts  $s'));
  }

  /// Сравнение MAC без учёта разделителей/регистра.
  bool _isHm10(String remoteId) =>
      remoteId.replaceAll(RegExp(r'[:\-\s]'), '').toUpperCase() ==
      kHm10Mac.replaceAll(':', '').toUpperCase();

  Future<bool> _ensurePermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    final ok = statuses[Permission.bluetoothScan]?.isGranted ?? false;
    final okConnect = statuses[Permission.bluetoothConnect]?.isGranted ?? false;
    if (!ok || !okConnect) {
      _addLog('✕ Нет разрешений Bluetooth');
      return false;
    }
    return true;
  }

  Future<void> _scan() async {
    if (_busy) return;
    if (!await _ensurePermissions()) return;
    setState(() {
      _busy = true;
      _devices = [];
      _selected = null;
    });
    _addLog('Скан 8 c…');
    try {
      final found = await Hm10Service.scan(onlyHmSoft: false);
      // HM10 (по MAC) — первым в списке и сразу выбран.
      ScanResult? hm10;
      for (final r in found) {
        if (_isHm10(r.device.remoteId.str)) {
          hm10 = r;
          break;
        }
      }
      final ordered = [
        ?hm10,
        ...found.where((r) => r != hm10),
      ];
      setState(() {
        _devices = ordered;
        _selected = hm10?.device ?? (found.isNotEmpty ? found.first.device : null);
      });
      if (hm10 != null) {
        _addLog('✓ HM10 найден по MAC: $kHm10Mac');
      } else if (found.isEmpty) {
        _addLog('✕ Ничего не найдено (проверь питание модуля и BT)');
      } else {
        _addLog('⚠ HM10 ($kHm10Mac) не виден. Можно открыть по MAC напрямую.');
      }
    } catch (e) {
      _addLog('✕ Ошибка скана: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    if (_busy) return;
    // Привязка по MAC: если ничего не выбрано — цепляемся к HM10 по адресу напрямую.
    final device = _selected ?? hm10Device();

    int cmd;
    int lockId;
    List<int> ident;
    try {
      cmd = int.parse(_cmd.text.trim().replaceAll('0x', ''), radix: 16);
      lockId = int.parse(
        _lock.text.trim().replaceAll('0x', '').replaceAll(' ', ''),
        radix: 16,
      );
      ident = parseIdent(_ident.text.trim());
    } catch (e) {
      _addLog('✕ Проверь поля: $e');
      return;
    }

    final List<int> payload;
    try {
      payload = buildPayload(lockId, cmd: cmd, ident: ident);
    } catch (e) {
      _addLog('✕ $e');
      return;
    }

    setState(() => _busy = true);
    _addLog(_testMode ? '→ ВИРТ. БАЗА' : '→ ${device.remoteId.str}');
    _addLog('TX: ${hexString(payload)}');
    try {
      if (_testMode) {
        await Future.delayed(const Duration(milliseconds: 200));
        final res = _db.handle(payload);
        _addLog('${res.ok ? "✓" : "✕"} ${res.message}');
        _addLog('RX: ${hexString(res.reply)}');
      } else {
        final resp = await openLockOnce(device, lockId, cmd: cmd, ident: ident);
        _addLog(resp.isEmpty
            ? '✓ Отправлено (ответа нет)'
            : '✓ RX: ${hexString(resp)}');
      }
    } catch (e) {
      _addLog('✕ Ошибка отправки: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  String _previewHex() {
    try {
      final cmd = int.parse(_cmd.text.trim().replaceAll('0x', ''), radix: 16);
      final lockId = int.parse(
        _lock.text.trim().replaceAll('0x', '').replaceAll(' ', ''),
        radix: 16,
      );
      final ident = parseIdent(_ident.text.trim());
      return hexString(buildPayload(lockId, cmd: cmd, ident: ident));
    } catch (e) {
      return 'проверь поля';
    }
  }

  String _deviceLabel(ScanResult r) {
    final mac = r.device.remoteId.str;
    if (_isHm10(mac)) return '🔓 HM10 (OBYEZD57A1)  ·  $mac  ·  ${r.rssi} dBm';
    final name =
        r.device.platformName.isNotEmpty ? r.device.platformName : '(без имени)';
    return '$name  ·  $mac  ·  ${r.rssi} dBm';
  }

  Color _logColor(String line) {
    if (line.contains('✓')) return kSuccess;
    if (line.contains('✕')) return kDanger;
    if (line.contains('⚠')) return kWarning;
    return kOnSurface;
  }

  @override
  Widget build(BuildContext context) {
    final selMac = _selected?.remoteId.str;
    final boundOk = selMac != null && _isHm10(selMac);

    return Scaffold(
      appBar: AppBar(title: const Text('HM10 · Замки')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Карточка цели (привязка по MAC)
            _card(
              child: Row(
                children: [
                  Icon(Icons.bluetooth,
                      color: boundOk ? kSuccess : kMuted, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('HM10 (привязка по MAC)',
                            style: TextStyle(color: kMuted, fontSize: 11)),
                        const SizedBox(height: 2),
                        Text(
                          selMac ?? kHm10Mac,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: kOnSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (boundOk)
                    const Icon(Icons.check_circle, color: kSuccess, size: 20),
                ],
              ),
            ),
            const SizedBox(height: 10),

            FilledButton.icon(
              onPressed: _busy ? null : _scan,
              icon: const Icon(Icons.search),
              label: Text(_busy ? 'Поиск…' : 'Найти HM10'),
            ),
            const SizedBox(height: 10),

            // Выбор устройства
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: kBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kDivider),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<BluetoothDevice>(
                  isExpanded: true,
                  dropdownColor: kSurface,
                  value: _selected,
                  hint: const Text('— нажми «Найти HM10» —',
                      style: TextStyle(color: kMuted)),
                  style: const TextStyle(color: kOnSurface, fontSize: 13),
                  items: _devices
                      .map((r) => DropdownMenuItem(
                            value: r.device,
                            child: Text(_deviceLabel(r),
                                overflow: TextOverflow.ellipsis),
                          ))
                      .toList(),
                  onChanged: _busy
                      ? null
                      : (d) => setState(() => _selected = d),
                ),
              ),
            ),
            const SizedBox(height: 12),

            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _cmd,
                    style: _mono,
                    decoration: const InputDecoration(
                        labelText: 'Команда (hex)', hintText: '87'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _lock,
                    style: _mono,
                    decoration: const InputDecoration(
                        labelText: 'Номер замка (hex)', hintText: '7702'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ident,
              style: _mono,
              decoration: const InputDecoration(
                labelText: 'ID устройства (байты 2–8)',
                hintText: 'токен 7 байт (14 hex)',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),

            // Превью пакета
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('ПАКЕТ К ОТПРАВКЕ',
                      style: TextStyle(fontSize: 11, color: kMuted)),
                  const SizedBox(height: 4),
                  Text(
                    _previewHex(),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: kPrimary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Тест-режим: виртуальная база вместо BLE
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.science, color: kWarning),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text('Виртуальная база (тест без BLE)',
                            style: TextStyle(color: kOnSurface)),
                      ),
                      Switch(
                        value: _testMode,
                        onChanged: (v) => setState(() => _testMode = v),
                      ),
                    ],
                  ),
                  if (_testMode) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Замки: ${_db.locks.map(VirtualLockDb.hex4).join(", ")}'
                      '   ·   ID: ${_db.authorized.length}',
                      style: const TextStyle(color: kMuted, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => LockDbPage(_db)),
                          );
                          if (mounted) setState(() {});
                        },
                        icon: const Icon(Icons.edit, size: 18, color: kPrimary),
                        label: const Text('Изменить базу',
                            style: TextStyle(color: kPrimary)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: kDivider),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),

            FilledButton.icon(
              onPressed: _busy ? null : _send,
              icon: Icon(_testMode ? Icons.science : Icons.lock_open),
              label: Text(_testMode ? 'Проверить по базе' : 'Открыть замок'),
            ),
            const SizedBox(height: 12),

            const Text('ЖУРНАЛ', style: TextStyle(color: kMuted, fontSize: 11)),
            const SizedBox(height: 4),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: kSurfaceHi,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: kDivider),
                ),
                child: _log.isEmpty
                    ? const Center(
                        child: Text('События появятся здесь',
                            style: TextStyle(color: kMuted)))
                    : ListView.builder(
                        itemCount: _log.length,
                        itemBuilder: (_, i) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Text(
                            _log[i],
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: _logColor(_log[i]),
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static const _mono = TextStyle(fontFamily: 'monospace', color: kOnSurface);

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kDivider),
        ),
        child: child,
      );
}
