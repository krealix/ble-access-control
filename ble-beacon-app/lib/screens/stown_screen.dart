import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/stown_packet.dart';
import '../services/hm10_sender.dart';
import '../services/stown_advertiser.dart';
import '../services/stown_storage.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Режим работы экрана: вещать метку в эфир или подключаться к HM-10 и слать.
enum StownMode { broadcast, send }

class StownScreen extends StatefulWidget {
  const StownScreen({super.key});

  @override
  State<StownScreen> createState() => _StownScreenState();
}

class _StownScreenState extends State<StownScreen> {
  final _advertiser = StownAdvertiser.instance;
  StownConfig _config = StownConfig.defaults;
  bool _advertising = false;
  bool _loaded = false;

  StownMode _mode = StownMode.send;

  // Отправка на HM-10
  final _sender = Hm10Sender.instance;
  StreamSubscription<List<ScanResult>>? _scanSub;
  bool _scanning = false;
  bool _sending = false;
  final List<ScanResult> _found = [];
  BluetoothDevice? _selectedDevice;
  String? _selectedName;
  final List<String> _sendLog = [];

  final _idCtrl = TextEditingController();
  final _companyCtrl = TextEditingController();
  final _serviceCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _sender.stopScan();
    _idCtrl.dispose();
    _companyCtrl.dispose();
    _serviceCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final cfg = await StownStorage.instance.load();
    if (!mounted) return;
    setState(() {
      _config = cfg;
      _idCtrl.text = cfg.identifierValueFor(cfg.identifierMode);
      _companyCtrl.text = '0x${cfg.companyId.toRadixString(16).padLeft(4, '0').toUpperCase()}';
      _serviceCtrl.text = cfg.serviceUuid;
      _nameCtrl.text = cfg.tagName;
      _loaded = true;
    });
  }

  // ---- Текущий пакет / превью ----

  Uint8List? _currentPacket() {
    if (_config.locks.isEmpty) return null;
    if (_config.selectedLock >= _config.locks.length) return null;
    try {
      final ident = StownPacket.buildIdentifier(
        _config.identifierMode,
        _idCtrl.text.trim(),
      );
      final lock = _config.locks[_config.selectedLock];
      final lockNum = StownPacket.parseLockNumber(lock.number);
      return StownPacket.build(
        command: _config.command,
        identifier: ident,
        lockNumber: lockNum,
      );
    } catch (_) {
      return null;
    }
  }

  void _storeIdValue() {
    final val = _idCtrl.text.trim();
    switch (_config.identifierMode) {
      case IdentifierMode.deviceId:
        _config = _config.copyWith(deviceId: val);
        break;
      case IdentifierMode.mac:
        _config = _config.copyWith(macValue: val);
        break;
      case IdentifierMode.uuid:
        _config = _config.copyWith(uuidValue: val);
        break;
      case IdentifierMode.phone:
        _config = _config.copyWith(phoneValue: val);
        break;
    }
  }

  void _syncWrapperParams() {
    final cid = int.tryParse(_companyCtrl.text.trim().replaceAll('0x', ''), radix: 16);
    _config = _config.copyWith(
      companyId: cid ?? _config.companyId,
      serviceUuid: _serviceCtrl.text.trim(),
      tagName: _nameCtrl.text.trim(),
    );
  }

  Future<void> _save() async {
    _storeIdValue();
    _syncWrapperParams();
    await StownStorage.instance.save(_config);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Настройки сохранены')),
      );
    }
  }

  Future<bool> _ensurePermissions() async {
    final res = await [
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
    ].request();
    return res.values.every((s) => s.isGranted);
  }

  Future<void> _toggle() async {
    if (_advertising) {
      try {
        await _advertiser.stop();
      } catch (_) {}
      if (mounted) setState(() => _advertising = false);
      return;
    }

    final packet = _currentPacket();
    if (packet == null) {
      _snack('Проверьте параметры (идентификатор / замок)');
      return;
    }
    await _save();

    if (!await _ensurePermissions()) {
      _snack('Нужны разрешения Bluetooth');
      return;
    }

    try {
      final supported = await _advertiser.isSupported();
      if (!supported) {
        _snack('Устройство не поддерживает BLE peripheral mode');
        return;
      }
      final state = await _advertiser.start(packet, _config);
      if (state == BluetoothPeripheralState.turnedOff) {
        _snack('Включите Bluetooth');
        return;
      }
      if (mounted) setState(() => _advertising = true);
    } on PlatformException catch (e) {
      _snack('Ошибка: ${e.message ?? e.code}');
    } catch (e) {
      _snack('Ошибка: $e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final packet = _currentPacket();

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        actions: [
          IconButton(
            icon: const Icon(Icons.casino_outlined, color: AppColors.primary),
            tooltip: 'Новый Device ID',
            onPressed: _advertising ? null : _newDeviceId,
          ),
          IconButton(
            icon: const Icon(Icons.save_outlined, color: AppColors.primary),
            tooltip: 'Сохранить',
            onPressed: _advertising ? null : _save,
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: AppColors.primary),
            tooltip: 'Выйти',
            onPressed: () => performLogout(
              context,
              onBeforeLogout: () async {
                if (_advertising) await _advertiser.stop();
              },
            ),
          ),
          const SizedBox(width: 8),
        ],
        title: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (_advertising || _sending)
                    ? AppColors.success
                    : AppColors.onSurfaceMuted,
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('STOWN-метка'),
                Text(
                  _mode == StownMode.broadcast
                      ? (_advertising ? 'Вещание активно' : 'Остановлена')
                      : (_sending
                          ? 'Отправка...'
                          : (_selectedDevice != null
                              ? 'HM-10 выбран'
                              : 'Выберите HM-10')),
                  style: const TextStyle(
                    color: AppColors.onSurfaceMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          const ThinDivider(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              children: [
                _modeCard(),
                const SizedBox(height: 12),
                _commandCard(),
                const SizedBox(height: 12),
                _identifierCard(),
                const SizedBox(height: 12),
                _locksCard(),
                const SizedBox(height: 12),
                if (_mode == StownMode.broadcast) ...[
                  _wrapperCard(),
                  const SizedBox(height: 12),
                ],
                _previewCard(packet),
                if (_mode == StownMode.send) ...[
                  const SizedBox(height: 12),
                  _deviceCard(),
                  const SizedBox(height: 12),
                  _logCard(),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: _mode == StownMode.broadcast
                  ? PrimaryGradientButton(
                      label: _advertising ? 'Остановить вещание' : 'Начать вещание',
                      icon: _advertising ? Icons.stop : Icons.play_arrow,
                      onPressed: _toggle,
                      color: _advertising ? AppColors.danger : null,
                    )
                  : PrimaryGradientButton(
                      label: _sending ? 'Отправка...' : 'Открыть замок',
                      icon: _sending ? Icons.hourglass_empty : Icons.lock_open,
                      onPressed: (_sending || _selectedDevice == null)
                          ? null
                          : _sendToHm10,
                    ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- Mode selector ----

  Widget _modeCard() {
    return StownCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionLabel('Режим'),
          const SizedBox(height: 8),
          _segment<StownMode>(
            options: const {
              StownMode.send: 'Отправка на HM-10',
              StownMode.broadcast: 'Вещание метки',
            },
            value: _mode,
            onChanged: (m) async {
              // При уходе из режима отправки — гасим скан.
              if (m != StownMode.send) {
                await _sender.stopScan();
                await _scanSub?.cancel();
                if (mounted) setState(() => _scanning = false);
              }
              if (mounted) setState(() => _mode = m);
            },
          ),
          const SizedBox(height: 8),
          Text(
            _mode == StownMode.send
                ? 'Подключение к модулю HM-10 и запись 10 байт в характеристику FFE1.'
                : 'Вещание 10 байт в эфир (если HM-10 сам сканирует).',
            style: const TextStyle(color: AppColors.onSurfaceMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  // ---- Device selection + send (HM-10) ----

  Widget _deviceCard() {
    return StownCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(child: SectionLabel('Устройство HM-10')),
              if (_scanning)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                IconButton(
                  icon: const Icon(Icons.refresh, color: AppColors.primary),
                  tooltip: 'Искать',
                  onPressed: _sending ? null : _startScan,
                ),
            ],
          ),
          if (_selectedDevice != null)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.primary),
              ),
              child: Row(
                children: [
                  const Icon(Icons.bluetooth_connected, color: AppColors.primary, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _selectedName ?? 'Выбрано',
                          style: const TextStyle(
                            color: AppColors.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          _selectedDevice!.remoteId.str,
                          style: const TextStyle(
                            color: AppColors.onSurfaceMuted,
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: _sending ? null : () => setState(() {
                      _selectedDevice = null;
                      _selectedName = null;
                    }),
                    child: const Text('Сменить'),
                  ),
                ],
              ),
            ),
          if (_selectedDevice == null) ...[
            if (_found.isEmpty && !_scanning)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Нажмите «Искать» — найдём HM-10 рядом',
                  style: TextStyle(color: AppColors.onSurfaceMuted),
                ),
              ),
            ..._found.map(_deviceTile),
          ],
        ],
      ),
    );
  }

  Widget _deviceTile(ScanResult r) {
    final isHm = Hm10Sender.looksLikeHm10(r);
    final name = r.advertisementData.advName.isEmpty
        ? '(без имени)'
        : r.advertisementData.advName;
    return InkWell(
      onTap: () => setState(() {
        _selectedDevice = r.device;
        _selectedName = name;
      }),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surfaceDim,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isHm ? AppColors.primary : AppColors.divider,
          ),
        ),
        child: Row(
          children: [
            Icon(
              isHm ? Icons.sensors : Icons.bluetooth,
              color: isHm ? AppColors.primary : AppColors.onSurfaceMuted,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      color: AppColors.onSurface,
                      fontWeight: isHm ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  Text(
                    r.device.remoteId.str,
                    style: const TextStyle(
                      color: AppColors.onSurfaceMuted,
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              '${r.rssi}',
              style: const TextStyle(color: AppColors.onSurfaceMuted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _logCard() {
    if (_sendLog.isEmpty) return const SizedBox.shrink();
    return StownCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionLabel('Журнал отправки'),
          const SizedBox(height: 6),
          ..._sendLog.map(
            (line) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                line,
                style: const TextStyle(
                  color: AppColors.onSurfaceMuted,
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- Cards ----

  Widget _commandCard() {
    return StownCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionLabel('Команда (первый байт)'),
          const SizedBox(height: 8),
          _segment<int>(
            options: const {kCmdOpen87: '0x87', kCmdOpen01: '0x01'},
            value: _config.command,
            onChanged: (v) => setState(() => _config = _config.copyWith(command: v)),
          ),
        ],
      ),
    );
  }

  Widget _identifierCard() {
    return StownCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionLabel('Идентификатор (байты 2-8)'),
          const SizedBox(height: 8),
          _segment<IdentifierMode>(
            options: const {
              IdentifierMode.deviceId: 'Device ID',
              IdentifierMode.phone: 'Номер',
              IdentifierMode.mac: 'MAC',
              IdentifierMode.uuid: 'UUID',
            },
            value: _config.identifierMode,
            onChanged: (mode) {
              _storeIdValue();
              setState(() {
                _config = _config.copyWith(identifierMode: mode);
                _idCtrl.text = _config.identifierValueFor(mode);
              });
            },
          ),
          const SizedBox(height: 12),
          _field(
            _idCtrl,
            _config.identifierMode == IdentifierMode.phone ? 'Номер телефона' : 'Значение',
            hint: switch (_config.identifierMode) {
              IdentifierMode.deviceId => 'Device ID: 14 hex-символов (7 байт)',
              IdentifierMode.phone =>
                'Только цифры. Кодируется в 7 байт (до ~17 цифр). Стабильный, читаемый ID',
              IdentifierMode.mac => 'MAC: 12 hex (6 байт). На iOS/Android реальный MAC недоступен',
              IdentifierMode.uuid => 'UUID: берутся первые 7 байт',
            },
            icon: _config.identifierMode == IdentifierMode.phone
                ? Icons.phone
                : Icons.fingerprint,
            keyboardType: _config.identifierMode == IdentifierMode.phone
                ? TextInputType.phone
                : TextInputType.text,
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
    );
  }

  Widget _locksCard() {
    return StownCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(child: SectionLabel('Замок (байты 9-10)')),
              IconButton(
                icon: const Icon(Icons.add_circle_outline, color: AppColors.primary),
                tooltip: 'Добавить замок',
                onPressed: _advertising ? null : _addLock,
              ),
            ],
          ),
          if (_config.locks.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Нет замков — добавьте',
                  style: TextStyle(color: AppColors.onSurfaceMuted)),
            )
          else
            ...List.generate(_config.locks.length, (i) => _lockTile(i)),
        ],
      ),
    );
  }

  Widget _lockTile(int idx) {
    final lock = _config.locks[idx];
    final selected = idx == _config.selectedLock;
    return InkWell(
      onTap: _advertising ? null : () => setState(() => _config = _config.copyWith(selectedLock: idx)),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withValues(alpha: 0.2) : AppColors.surfaceDim,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.divider,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: selected ? AppColors.primary : AppColors.onSurfaceMuted,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                lock.name,
                style: TextStyle(
                  color: AppColors.onSurface,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
            Text(
              '0x${lock.number}',
              style: const TextStyle(
                color: AppColors.onSurfaceMuted,
                fontFamily: 'monospace',
                fontSize: 13,
              ),
            ),
            if (!_advertising)
              IconButton(
                icon: const Icon(Icons.close, color: AppColors.danger, size: 18),
                onPressed: () => _removeLock(idx),
              ),
          ],
        ),
      ),
    );
  }

  Widget _wrapperCard() {
    return StownCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionLabel('Обёртка в эфире'),
          const SizedBox(height: 8),
          _segment<WrapperFormat>(
            options: const {
              WrapperFormat.manufacturer: 'Manufacturer',
              WrapperFormat.service: 'Service',
              WrapperFormat.ibeacon: 'iBeacon',
            },
            value: _config.wrapper,
            onChanged: (w) => setState(() => _config = _config.copyWith(wrapper: w)),
          ),
          const SizedBox(height: 12),
          if (_config.wrapper == WrapperFormat.manufacturer)
            _field(
              _companyCtrl,
              'Company ID (hex)',
              hint: '0xFFFF — тестовый идентификатор',
              icon: Icons.business,
              onChanged: (_) => setState(() {}),
            ),
          if (_config.wrapper == WrapperFormat.service)
            _field(
              _serviceCtrl,
              'Service UUID (16-bit)',
              hint: 'Напр. FFF0 — развернётся в полный Base UUID',
              icon: Icons.bookmark_outline,
              onChanged: (_) => setState(() {}),
            ),
          if (_config.wrapper == WrapperFormat.ibeacon)
            const Text(
              '10 байт упаковываются в iBeacon: первые 10 байт → UUID, '
              'номер замка → Minor. Единственный способ для совместимости с iOS.',
              style: TextStyle(color: AppColors.onSurfaceMuted, fontSize: 12),
            ),
          const SizedBox(height: 12),
          _field(
            _nameCtrl,
            'Имя метки',
            hint: _config.wrapper == WrapperFormat.ibeacon
                ? 'iBeacon: имя не влезает в пакет — не будет видно в сканере. '
                    'Имя работает на Manufacturer/Service.'
                : 'Видно в сканере вместо «Неизвестное устройство». До 12 символов. '
                    'На Android временно меняет имя Bluetooth телефона (вернётся при остановке).',
            icon: Icons.label_outline,
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
    );
  }

  Widget _previewCard(Uint8List? packet) {
    return StownCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionLabel('Пакет (10 байт)'),
          const SizedBox(height: 6),
          if (packet == null)
            const Text(
              '— некорректные параметры —',
              style: TextStyle(color: AppColors.danger, fontFamily: 'monospace', fontSize: 16),
            )
          else ...[
            SelectableText(
              StownPacket.format(packet),
              style: const TextStyle(
                color: AppColors.success,
                fontFamily: 'monospace',
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'В эфире: ${StownAdvertiser.wirePreview(packet, _config)}',
              style: const TextStyle(
                color: AppColors.onSurfaceMuted,
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---- Generic segment selector ----

  Widget _segment<T>({
    required Map<T, String> options,
    required T value,
    required ValueChanged<T> onChanged,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceDim,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        children: options.entries.map((e) {
          final selected = e.key == value;
          return Expanded(
            child: GestureDetector(
              onTap: _advertising ? null : () => onChanged(e.key),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                margin: const EdgeInsets.all(3),
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  gradient: selected ? primaryGradient : null,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Center(
                  child: Text(
                    e.value,
                    style: TextStyle(
                      color: selected ? Colors.white : AppColors.onSurfaceMuted,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _field(
    TextEditingController c,
    String label, {
    String? hint,
    IconData? icon,
    ValueChanged<String>? onChanged,
    TextInputType? keyboardType,
  }) {
    return TextField(
      controller: c,
      enabled: !_advertising,
      onChanged: onChanged,
      keyboardType: keyboardType,
      style: const TextStyle(
        color: AppColors.onSurface,
        fontFamily: 'monospace',
        fontSize: 14,
      ),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: icon == null ? null : Icon(icon),
        helperText: hint,
        helperStyle: const TextStyle(
          color: AppColors.onSurfaceMuted,
          fontSize: 11,
          height: 1.4,
        ),
        helperMaxLines: 3,
      ),
    );
  }

  // ---- HM-10 scan & send ----

  Future<bool> _ensureScanPermissions() async {
    final res = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    return res[Permission.bluetoothScan]?.isGranted == true &&
        res[Permission.bluetoothConnect]?.isGranted == true;
  }

  Future<void> _startScan() async {
    if (!await _ensureScanPermissions()) {
      _snack('Нужны разрешения Bluetooth');
      return;
    }
    setState(() {
      _found.clear();
      _scanning = true;
    });
    _scanSub?.cancel();
    _scanSub = _sender.scanResults.listen((results) {
      if (!mounted) return;
      setState(() {
        _found
          ..clear()
          ..addAll(results);
        // HM-10 кандидаты вверх, потом по RSSI
        _found.sort((a, b) {
          final ah = Hm10Sender.looksLikeHm10(a) ? 0 : 1;
          final bh = Hm10Sender.looksLikeHm10(b) ? 0 : 1;
          if (ah != bh) return ah - bh;
          return b.rssi.compareTo(a.rssi);
        });
      });
    });
    try {
      await _sender.startScan(timeout: const Duration(seconds: 8));
    } catch (e) {
      _snack('Ошибка сканирования: $e');
    }
    // Через таймаут скан сам остановится — снимем индикатор
    Future.delayed(const Duration(seconds: 8), () {
      if (mounted) setState(() => _scanning = false);
    });
  }

  Future<void> _sendToHm10() async {
    final device = _selectedDevice;
    if (device == null) return;
    final packet = _currentPacket();
    if (packet == null) {
      _snack('Проверьте параметры пакета');
      return;
    }
    // Останавливаем скан перед подключением
    await _sender.stopScan();
    await _scanSub?.cancel();
    if (!mounted) return;

    setState(() {
      _sending = true;
      _scanning = false;
      _sendLog.clear();
    });

    try {
      await _sender.sendPacket(
        device,
        packet,
        onLog: (m) {
          if (mounted) setState(() => _sendLog.add(m));
        },
      );
      if (mounted) {
        _snack('Команда отправлена: ${StownPacket.format(packet)}');
      }
    } on Hm10Exception catch (e) {
      if (mounted) {
        setState(() => _sendLog.add('ОШИБКА: ${e.message}'));
        _snack(e.message);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _sendLog.add('ОШИБКА: $e'));
        _snack('Ошибка: $e');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // ---- Actions ----

  void _newDeviceId() {
    setState(() {
      final newId = StownPacket.generateDeviceId();
      _config = _config.copyWith(deviceId: newId);
      if (_config.identifierMode == IdentifierMode.deviceId) {
        _idCtrl.text = newId;
      }
    });
  }

  Future<void> _addLock() async {
    final nameCtrl = TextEditingController();
    final numberCtrl = TextEditingController();
    final result = await showDialog<GateLock?>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        title: const Text('Новый замок', style: TextStyle(color: AppColors.onSurface)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              style: const TextStyle(color: AppColors.onSurface),
              decoration: const InputDecoration(
                labelText: 'Название',
                prefixIcon: Icon(Icons.lock_outline),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: numberCtrl,
              style: const TextStyle(color: AppColors.onSurface, fontFamily: 'monospace'),
              decoration: const InputDecoration(
                labelText: 'Номер (hex), напр. 7704',
                prefixIcon: Icon(Icons.tag),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () {
              final name = nameCtrl.text.trim();
              final number = numberCtrl.text.trim().replaceAll('0x', '');
              if (name.isEmpty || number.isEmpty) return;
              try {
                StownPacket.parseLockNumber(number);
              } catch (_) {
                return;
              }
              Navigator.pop(ctx, GateLock(name: name, number: number));
            },
            style: FilledButton.styleFrom(minimumSize: const Size(80, 40)),
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
    if (result == null) return;
    final newLocks = List<GateLock>.from(_config.locks)..add(result);
    final updated = _config.copyWith(
      locks: newLocks,
      selectedLock: newLocks.length - 1,
    );
    await StownStorage.instance.save(updated);
    if (mounted) setState(() => _config = updated);
  }

  Future<void> _removeLock(int idx) async {
    final newLocks = List<GateLock>.from(_config.locks)..removeAt(idx);
    var sel = _config.selectedLock;
    if (sel >= newLocks.length) sel = newLocks.isEmpty ? 0 : newLocks.length - 1;
    final updated = _config.copyWith(locks: newLocks, selectedLock: sel);
    await StownStorage.instance.save(updated);
    if (mounted) setState(() => _config = updated);
  }
}
