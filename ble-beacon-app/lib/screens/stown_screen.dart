import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/stown_packet.dart';
import '../services/bt_info.dart';
import '../services/stown_advertiser.dart';
import '../services/stown_storage.dart';
import '../theme.dart';
import '../widgets/common.dart';

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

  final _cmdCtrl = TextEditingController();
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
    _cmdCtrl.dispose();
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
      _cmdCtrl.text = _hex2(cfg.command);
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
      case IdentifierMode.imei:
        _config = _config.copyWith(imeiValue: val);
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
      if (_advertiser.lastNameDropped) {
        _snack('Метка вещается, но без имени — телефон не поддержал имя в пакете');
      }
    } on PlatformException catch (e) {
      await _showAdvertiseError('код ${e.code} — ${e.message ?? ""}');
    } catch (e) {
      await _showAdvertiseError('$e');
    }
  }

  /// Подробная диагностика ошибки вещания: код + возможности адаптера.
  Future<void> _showAdvertiseError(String detail) async {
    final support = await BtInfo.advertiseSupportSummary();
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        title: const Text('Ошибка вещания',
            style: TextStyle(color: AppColors.onSurface)),
        content: SelectableText(
          'ADVERTISE_FAILED: $detail\n\nПоддержка адаптера:\n$support',
          style: const TextStyle(
              color: AppColors.onSurface, fontFamily: 'monospace', fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
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
                color: _advertising
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
                  _advertising ? 'Вещание активно' : 'Остановлена',
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
                _commandCard(),
                const SizedBox(height: 12),
                _identifierCard(),
                const SizedBox(height: 12),
                _locksCard(),
                const SizedBox(height: 12),
                _wrapperCard(),
                const SizedBox(height: 12),
                _previewCard(packet),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: PrimaryGradientButton(
                label: _advertising ? 'Остановить вещание' : 'Начать вещание',
                icon: _advertising ? Icons.stop : Icons.play_arrow,
                onPressed: _toggle,
                color: _advertising ? AppColors.danger : null,
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Свободный ввод байта в hex (00–FF).
              SizedBox(
                width: 104,
                child: TextField(
                  controller: _cmdCtrl,
                  enabled: !_advertising,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')),
                    LengthLimitingTextInputFormatter(2),
                  ],
                  onChanged: _onCommandHexChanged,
                  style: const TextStyle(
                    color: AppColors.onSurface,
                    fontFamily: 'monospace',
                    fontSize: 18,
                    letterSpacing: 3,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'HEX',
                    prefixText: '0x',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Быстрые пресеты стандартных команд STOWN.
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: [
                    _cmdPreset(kCmdOpen87),
                    _cmdPreset(kCmdOpen01),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Любой байт 00–FF. Стандарт STOWN: 87 или 01. '
            'Свой код поймёт только настоящий контроллер.',
            style: TextStyle(
              color: AppColors.onSurfaceMuted,
              fontSize: 11,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  /// Кнопка-пресет команды (подсвечивается, если совпадает с текущим байтом).
  Widget _cmdPreset(int value) {
    final selected = _config.command == value;
    return GestureDetector(
      onTap: _advertising ? null : () => _setCommand(value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          gradient: selected ? primaryGradient : null,
          color: selected ? null : AppColors.surfaceDim,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Text(
          '0x${_hex2(value)}',
          style: TextStyle(
            color: selected ? Colors.white : AppColors.onSurfaceMuted,
            fontWeight: FontWeight.w600,
            fontSize: 13,
            fontFamily: 'monospace',
          ),
        ),
      ),
    );
  }

  /// Байт → две заглавные hex-цифры ('87').
  String _hex2(int b) => b.toRadixString(16).padLeft(2, '0').toUpperCase();

  /// Ручной ввод hex: парсим и кладём в config (пустое/некорректное игнорируем).
  void _onCommandHexChanged(String s) {
    final v = int.tryParse(s.trim(), radix: 16);
    if (v == null) return;
    setState(() => _config = _config.copyWith(command: v & 0xFF));
  }

  /// Выбор пресета: пишем и в config, и в поле ввода.
  void _setCommand(int value) {
    setState(() {
      _config = _config.copyWith(command: value);
      _cmdCtrl.text = _hex2(value);
    });
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
              IdentifierMode.deviceId: 'Device',
              IdentifierMode.phone: 'Номер',
              IdentifierMode.imei: 'IMEI',
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
            switch (_config.identifierMode) {
              IdentifierMode.phone => 'Номер телефона',
              IdentifierMode.imei => 'IMEI',
              _ => 'Значение',
            },
            hint: switch (_config.identifierMode) {
              IdentifierMode.deviceId => 'Device ID: 14 hex-символов (7 байт)',
              IdentifierMode.phone =>
                'Только цифры, максимум 14. BCD-упаковка в 7 байт (по 2 цифры на байт)',
              IdentifierMode.imei =>
                'IMEI 15 цифр; кодируем первые 14 (BCD). На Android 10+ авточтение IMEI '
                    'запрещено системой — вводите вручную',
              IdentifierMode.mac => 'MAC: 12 hex (6 байт). На iOS/Android реальный MAC недоступен',
              IdentifierMode.uuid => 'UUID: берутся первые 7 байт',
            },
            icon: switch (_config.identifierMode) {
              IdentifierMode.phone => Icons.phone,
              IdentifierMode.imei => Icons.smartphone,
              _ => Icons.fingerprint,
            },
            keyboardType: _isDigitsMode(_config.identifierMode)
                ? TextInputType.phone
                : TextInputType.text,
            inputFormatters: _isDigitsMode(_config.identifierMode)
                ? [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(StownPacket.kBcdMaxDigits),
                  ]
                : null,
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

  /// true для режимов, где вводятся только цифры (телефон / IMEI → BCD).
  bool _isDigitsMode(IdentifierMode m) =>
      m == IdentifierMode.phone || m == IdentifierMode.imei;

  Widget _field(
    TextEditingController c,
    String label, {
    String? hint,
    IconData? icon,
    ValueChanged<String>? onChanged,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return TextField(
      controller: c,
      enabled: !_advertising,
      onChanged: onChanged,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
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
