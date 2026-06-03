// Демо-экран: найти HM10, собрать пакет, открыть замок.
// Вставь в свой Flutter-проект и открой как обычную страницу:
//   Navigator.push(context, MaterialPageRoute(builder: (_) => const LockSendPage()));
//
// Зависимости: flutter_blue_plus, permission_handler (см. README.md).

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'hm10_service.dart';

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

  Future<bool> _ensurePermissions() async {
    // Android 12+: scan + connect. Старее — location. iOS — через Info.plist.
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
      final found = await Hm10Service.scan();
      setState(() {
        _devices = found;
        _selected = found.isNotEmpty ? found.first.device : null;
      });
      _addLog(found.isEmpty
          ? '✕ HM10 не найден (проверь питание модуля и BT)'
          : '✓ Найдено: ${found.length}');
    } catch (e) {
      _addLog('✕ Ошибка скана: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    if (_busy) return;
    final device = _selected;
    if (device == null) {
      _addLog('✕ Сначала выбери HM10');
      return;
    }

    int cmd;
    int lockId;
    List<int> ident;
    try {
      cmd = int.parse(_cmd.text.trim().replaceAll('0x', ''), radix: 16);
      lockId = int.parse(
          _lock.text.trim().replaceAll('0x', '').replaceAll(' ', ''),
          radix: 16);
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
    _addLog('TX: ${hexString(payload)}');
    try {
      final resp = await openLockOnce(device, lockId, cmd: cmd, ident: ident);
      _addLog(resp.isEmpty
          ? '✓ Отправлено (ответа нет)'
          : '✓ RX: ${hexString(resp)}');
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
          radix: 16);
      final ident = parseIdent(_ident.text.trim());
      return hexString(buildPayload(lockId, cmd: cmd, ident: ident));
    } catch (e) {
      return 'проверь поля';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Замки (HM10)')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : _scan,
              icon: const Icon(Icons.search),
              label: const Text('Найти HM10'),
            ),
            const SizedBox(height: 8),
            DropdownButton<BluetoothDevice>(
              isExpanded: true,
              value: _selected,
              hint: const Text('— устройство не выбрано —'),
              items: _devices
                  .map((r) => DropdownMenuItem(
                        value: r.device,
                        child: Text(
                          '${r.device.platformName.isNotEmpty ? r.device.platformName : "HM10"}'
                          '  ·  ${r.device.remoteId}  ·  ${r.rssi} dBm',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ))
                  .toList(),
              onChanged: _busy
                  ? null
                  : (d) => setState(() => _selected = d),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _cmd,
                    decoration: const InputDecoration(
                      labelText: 'Команда (hex)',
                      hintText: '87',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _lock,
                    decoration: const InputDecoration(
                      labelText: 'Номер замка (hex)',
                      hintText: '7702',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ident,
              decoration: const InputDecoration(
                labelText: 'Идентификатор / MAC (опц.)',
                hintText: 'AA:BB:CC:DD:EE:FF',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('ПАКЕТ К ОТПРАВКЕ',
                        style: TextStyle(fontSize: 11, color: Colors.grey)),
                    const SizedBox(height: 4),
                    Text(_previewHex(),
                        style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 18,
                            fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _send,
              icon: const Icon(Icons.lock_open),
              label: const Text('Открыть замок'),
            ),
            const SizedBox(height: 12),
            const Text('Журнал', style: TextStyle(color: Colors.grey)),
            Expanded(
              child: Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  reverse: false,
                  itemCount: _log.length,
                  itemBuilder: (_, i) => Text(
                    _log[i],
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
