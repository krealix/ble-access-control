import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../models/beacon.dart';
import '../services/beacon_advertiser.dart';
import '../services/bt_info.dart';
import '../services/preset_storage.dart';
import '../theme.dart';
import '../widgets/common.dart';

class GeneratorScreen extends StatefulWidget {
  const GeneratorScreen({super.key});

  @override
  State<GeneratorScreen> createState() => _GeneratorScreenState();
}

class _GeneratorScreenState extends State<GeneratorScreen> {
  static const _uuidGen = Uuid();
  final _rng = Random.secure();
  final _advertiser = BeaconAdvertiser.instance;

  BeaconKind _kind = BeaconKind.iBeacon;
  bool _advertising = false;
  List<BeaconPreset> _presets = [];
  String? _localMac;
  bool _localMacIsMock = false;

  final _uuidCtrl = TextEditingController();
  final _majorCtrl = TextEditingController();
  final _minorCtrl = TextEditingController();
  final _txCtrl = TextEditingController(text: '-59');
  final _namespaceCtrl = TextEditingController();
  final _instanceCtrl = TextEditingController();
  final _urlCtrl = TextEditingController(text: 'https://flutter.dev');
  final _serviceUuidCtrl = TextEditingController();
  final _mfrDataCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _randomFill();
    _loadPresets();
    _loadLocalMac();
  }

  Future<void> _loadLocalMac() async {
    final mac = await BtInfo.getBluetoothMac();
    if (!mounted) return;
    setState(() {
      _localMac = mac;
      _localMacIsMock = BtInfo.isMockMac(mac);
    });
  }

  Future<void> _copyMac() async {
    if (_localMac == null) return;
    await Clipboard.setData(ClipboardData(text: _localMac!));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('MAC $_localMac скопирован')),
    );
  }

  @override
  void dispose() {
    _uuidCtrl.dispose();
    _majorCtrl.dispose();
    _minorCtrl.dispose();
    _txCtrl.dispose();
    _namespaceCtrl.dispose();
    _instanceCtrl.dispose();
    _urlCtrl.dispose();
    _serviceUuidCtrl.dispose();
    _mfrDataCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadPresets() async {
    final list = await PresetStorage.instance.load();
    if (mounted) setState(() => _presets = list);
  }

  String _randomHex(int bytes) => List.generate(bytes, (_) => _rng.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();

  void _randomFill() {
    setState(() {
      _uuidCtrl.text = _uuidGen.v4();
      _majorCtrl.text = _rng.nextInt(0x10000).toString();
      _minorCtrl.text = _rng.nextInt(0x10000).toString();
      _namespaceCtrl.text = _randomHex(10);
      _instanceCtrl.text = _randomHex(6);
      _serviceUuidCtrl.text = _uuidGen.v4().toUpperCase();
      _mfrDataCtrl.text = _randomHex(_rng.nextInt(6) + 2);
    });
  }

  BeaconPreset _currentPreset({String? id, String? name}) => BeaconPreset(
        id: id ?? _uuidGen.v4(),
        name: name ?? 'Без названия',
        kind: _kind,
        uuid: _uuidCtrl.text.trim(),
        major: int.tryParse(_majorCtrl.text.trim()) ?? 0,
        minor: int.tryParse(_minorCtrl.text.trim()) ?? 0,
        txPower: int.tryParse(_txCtrl.text.trim()) ?? -59,
        namespace: _namespaceCtrl.text.trim(),
        instance: _instanceCtrl.text.trim(),
        url: _urlCtrl.text.trim(),
        serviceUuid: _serviceUuidCtrl.text.trim(),
        manufacturerData: _mfrDataCtrl.text.trim(),
      );

  void _applyPreset(BeaconPreset p) {
    setState(() {
      _kind = p.kind;
      _uuidCtrl.text = p.uuid;
      _majorCtrl.text = p.major.toString();
      _minorCtrl.text = p.minor.toString();
      _txCtrl.text = p.txPower.toString();
      _namespaceCtrl.text = p.namespace;
      _instanceCtrl.text = p.instance;
      _urlCtrl.text = p.url;
      _serviceUuidCtrl.text = p.serviceUuid;
      _mfrDataCtrl.text = p.manufacturerData;
    });
  }

  Future<bool> _ensurePermissions() async {
    final res = await [
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
    ].request();
    return res.values.every((s) => s.isGranted);
  }

  Future<void> _toggleAdvertise() async {
    if (_advertising) {
      try {
        await _advertiser.stop();
      } catch (_) {}
      if (mounted) setState(() => _advertising = false);
      return;
    }
    if (!await _ensurePermissions()) {
      _snack('Нужны разрешения Bluetooth');
      return;
    }
    try {
      final supported = await _advertiser.isSupported();
      if (!supported) {
        _snack('Это устройство не поддерживает BLE peripheral mode');
        return;
      }
      final state = await _advertiser.start(_currentPreset());
      if (state == BluetoothPeripheralState.turnedOff) {
        _snack('Включите Bluetooth');
        return;
      }
      if (state == BluetoothPeripheralState.unsupported) {
        _snack('BLE peripheral не поддерживается');
        return;
      }
      if (mounted) setState(() => _advertising = true);
    } on ArgumentError catch (e) {
      _snack(e.message?.toString() ?? 'Некорректные параметры');
    } on PlatformException catch (e) {
      _snack('Платформенная ошибка: ${e.message ?? e.code}');
    } catch (e) {
      _snack('Ошибка: $e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _savePresetDialog() async {
    final ctrl = TextEditingController(text: _kind.label);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        title: const Text('Сохранить пресет', style: TextStyle(color: AppColors.onSurface)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: AppColors.onSurface),
          decoration: const InputDecoration(labelText: 'Название'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            style: FilledButton.styleFrom(minimumSize: const Size(80, 40)),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final preset = _currentPreset(name: name);
    final list = await PresetStorage.instance.add(preset);
    if (mounted) {
      setState(() => _presets = list);
      _snack('Пресет «$name» сохранён');
    }
  }

  Future<void> _deletePreset(BeaconPreset p) async {
    final list = await PresetStorage.instance.remove(p.id);
    if (mounted) setState(() => _presets = list);
  }

  Color _kindColor(BeaconKind k) => switch (k) {
        BeaconKind.iBeacon => AppColors.primaryLight,
        BeaconKind.eddystoneUid => AppColors.success,
        BeaconKind.eddystoneUrl => const Color(0xFFFFB74D),
        BeaconKind.custom => const Color(0xFF4DD0E1),
        _ => AppColors.onSurfaceMuted,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        title: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _advertising ? AppColors.success : AppColors.onSurfaceMuted,
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Генератор'),
                Text(
                  _advertising ? 'Вещание активно' : 'Остановлен',
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
        actions: [
          IconButton(
            icon: const Icon(Icons.casino_outlined, color: AppColors.primary),
            tooltip: 'Случайные значения',
            onPressed: _advertising ? null : _randomFill,
          ),
          IconButton(
            icon: const Icon(Icons.save_outlined, color: AppColors.primary),
            tooltip: 'Сохранить пресет',
            onPressed: _advertising ? null : _savePresetDialog,
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: AppColors.primary),
            tooltip: 'Выйти',
            onPressed: () => performLogout(
              context,
              onBeforeLogout: () async {
                if (_advertising) {
                  await _advertiser.stop();
                }
              },
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          const ThinDivider(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              children: [
                _macCard(),
                const SizedBox(height: 12),
                _kindSelector(),
                if (_presets.isNotEmpty) ...[
                  const SectionLabel('Пресеты'),
                  _presetsBar(),
                ],
                const SectionLabel('Параметры'),
                _formFor(_kind),
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
                onPressed: _toggleAdvertise,
                color: _advertising ? AppColors.danger : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _macCard() {
    final mac = _localMac;
    final accent = _localMacIsMock ? const Color(0xFFFFB74D) : AppColors.primaryLight;
    return StownCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(
            _localMacIsMock ? Icons.warning_amber_outlined : Icons.qr_code_2,
            color: accent,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'MAC АДАПТЕРА',
                  style: TextStyle(
                    color: AppColors.onSurfaceMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                  ),
                ),
                SelectableText(
                  mac ?? 'Не удалось получить',
                  style: TextStyle(
                    color: accent,
                    fontFamily: 'monospace',
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  _localMacIsMock
                      ? 'Android прячет реальный MAC (приватность). '
                          'В эфире при advertising будет случайный.'
                      : 'Этот MAC можно вставить в whitelist Шлюза.',
                  style: const TextStyle(
                    color: AppColors.onSurfaceMuted,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          if (mac != null) ...[
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.copy, color: AppColors.primary),
              tooltip: 'Скопировать',
              onPressed: _copyMac,
            ),
          ],
        ],
      ),
    );
  }

  Widget _kindSelector() {
    Widget tab(BeaconKind k, String label) {
      final selected = _kind == k;
      return Expanded(
        child: GestureDetector(
          onTap: _advertising ? null : () => setState(() => _kind = k),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.all(4),
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              gradient: selected ? primaryGradient : null,
              color: selected ? null : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? Colors.white : AppColors.onSurfaceMuted,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          tab(BeaconKind.iBeacon, 'iBeacon'),
          tab(BeaconKind.eddystoneUid, 'Eddy UID'),
          tab(BeaconKind.eddystoneUrl, 'Eddy URL'),
          tab(BeaconKind.custom, 'Custom'),
        ],
      ),
    );
  }

  Widget _presetsBar() {
    return SizedBox(
      height: 84,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _presets.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final p = _presets[i];
          final color = _kindColor(p.kind);
          return GestureDetector(
            onTap: _advertising ? null : () => _applyPreset(p),
            onLongPress: () => _confirmDelete(p),
            child: Container(
              width: 160,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.divider),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(Icons.bookmark, color: color, size: 16),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          p.name,
                          style: const TextStyle(
                            color: AppColors.onSurface,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  KindBadge(label: p.kind.label, color: color),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirmDelete(BeaconPreset p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        title: Text('Удалить «${p.name}»?', style: const TextStyle(color: AppColors.onSurface)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              minimumSize: const Size(80, 40),
            ),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok == true) await _deletePreset(p);
  }

  Widget _formFor(BeaconKind k) {
    switch (k) {
      case BeaconKind.iBeacon:
        return Column(
          children: [
            _textField(
              _uuidCtrl,
              'UUID',
              icon: Icons.fingerprint,
              hint:
                  '16 байт в формате 8-4-4-4-12. Общий идентификатор всей группы маяков.',
            ),
            const SizedBox(height: 12),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: _textField(
                  _majorCtrl,
                  'Major',
                  icon: Icons.tag,
                  numeric: true,
                  hint: '0–65535. Группа\n(например, номер магазина).',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _textField(
                  _minorCtrl,
                  'Minor',
                  icon: Icons.tag,
                  numeric: true,
                  hint: '0–65535. Конкретный\nмаяк в группе.',
                ),
              ),
            ]),
            const SizedBox(height: 12),
            _textField(
              _txCtrl,
              'TX Power (dBm)',
              icon: Icons.signal_cellular_alt,
              numeric: true,
              allowNegative: true,
              hint:
                  'Калиброванный RSSI на 1 метре. Обычно -59 для телефонов в роли маяка.',
            ),
          ],
        );
      case BeaconKind.eddystoneUid:
        return Column(
          children: [
            _textField(
              _namespaceCtrl,
              'Namespace (10 байт hex)',
              icon: Icons.bookmark_outline,
              hint:
                  '20 hex-символов. Идентификатор организации, общий для всех маяков.',
            ),
            const SizedBox(height: 12),
            _textField(
              _instanceCtrl,
              'Instance (6 байт hex)',
              icon: Icons.numbers,
              hint:
                  '12 hex-символов. Номер конкретного маяка внутри namespace.',
            ),
            const SizedBox(height: 12),
            _textField(
              _txCtrl,
              'TX Power (dBm)',
              icon: Icons.signal_cellular_alt,
              numeric: true,
              allowNegative: true,
              hint: 'Калиброванный RSSI на 1 м. Обычно -20…-59 dBm.',
            ),
          ],
        );
      case BeaconKind.eddystoneUrl:
        return Column(
          children: [
            _textField(
              _urlCtrl,
              'URL',
              icon: Icons.link,
              hint:
                  'Полный адрес со схемой. Максимум 17 символов после http(s)://. '
                  'Используйте сокращалки или короткие домены.',
            ),
            const SizedBox(height: 12),
            _textField(
              _txCtrl,
              'TX Power (dBm)',
              icon: Icons.signal_cellular_alt,
              numeric: true,
              allowNegative: true,
              hint: 'Калиброванный RSSI на 1 м. Обычно -20…-59 dBm.',
            ),
          ],
        );
      case BeaconKind.custom:
        return Column(
          children: [
            _textField(
              _serviceUuidCtrl,
              'Service UUID',
              icon: Icons.fingerprint,
              hint:
                  'Полный 128-битный UUID 8-4-4-4-12. Можно оставить пустым.',
            ),
            const SizedBox(height: 12),
            _textField(
              _mfrDataCtrl,
              'Manufacturer Data (hex)',
              icon: Icons.code,
              hint:
                  'Произвольные байты в hex. Передаётся с тестовым '
                  'Manufacturer ID 0xFFFF. Макс ~20 байт.',
            ),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _textField(
    TextEditingController c,
    String label, {
    IconData? icon,
    String? hint,
    bool numeric = false,
    bool allowNegative = false,
  }) {
    return TextField(
      controller: c,
      enabled: !_advertising,
      style: const TextStyle(
        color: AppColors.onSurface,
        fontFamily: 'monospace',
        fontSize: 14,
      ),
      keyboardType: numeric
          ? TextInputType.numberWithOptions(signed: allowNegative)
          : TextInputType.text,
      inputFormatters: numeric
          ? [
              FilteringTextInputFormatter.allow(
                allowNegative
                    ? RegExp(r'^-?\d*')
                    : RegExp(r'^\d*'),
              ),
            ]
          : null,
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
}
