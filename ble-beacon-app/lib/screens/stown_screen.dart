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

/// Экран «Метка»: это просто метка-пропуск. Она ничего не знает про замок и
/// формат команды — только свой идентификатор и имя. В эфир уходит STOWN-пакет
/// (manufacturer) с этим ID; шлюз сам решает, что открывать.
class StownScreen extends StatefulWidget {
  const StownScreen({super.key, this.standalone = false});

  /// true — отдельное приложение «Метка» (без вкладок/входа): прячем выход.
  final bool standalone;

  @override
  State<StownScreen> createState() => _StownScreenState();
}

class _StownScreenState extends State<StownScreen> {
  final _advertiser = StownAdvertiser.instance;
  StownConfig _config = StownConfig.defaults;
  bool _advertising = false;
  bool _loaded = false;

  final _idCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _idCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final cfg = await StownStorage.instance.load();
    if (!mounted) return;
    setState(() {
      // Метка всегда: deviceId-идентификатор + manufacturer-обёртка.
      _config = cfg.copyWith(
        identifierMode: IdentifierMode.deviceId,
        wrapper: WrapperFormat.manufacturer,
      );
      _idCtrl.text = _config.deviceId.isEmpty
          ? StownPacket.generateDeviceId()
          : _config.deviceId;
      _nameCtrl.text = _config.tagName;
      _loaded = true;
    });
  }

  /// 10 байт для эфира: [0x87][id×7][00 00]. Замок/команда метке не важны —
  /// это лишь носитель идентификатора, который опознаёт шлюз.
  Uint8List? _currentPacket() {
    try {
      final ident =
          StownPacket.buildIdentifier(IdentifierMode.deviceId, _idCtrl.text.trim());
      return StownPacket.build(command: kCmdOpen87, identifier: ident, lockNumber: 0);
    } catch (_) {
      return null;
    }
  }

  Future<void> _save() async {
    _config = _config.copyWith(
      deviceId: _idCtrl.text.trim(),
      tagName: _nameCtrl.text.trim(),
      identifierMode: IdentifierMode.deviceId,
      wrapper: WrapperFormat.manufacturer,
    );
    await StownStorage.instance.save(_config);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сохранено')),
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
      _snack('Проверьте идентификатор (нужны hex-символы)');
      return;
    }
    await _save();

    if (!await _ensurePermissions()) {
      _snack('Нужны разрешения Bluetooth');
      return;
    }

    try {
      if (!await _advertiser.isSupported()) {
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

  void _newDeviceId() {
    setState(() => _idCtrl.text = StownPacket.generateDeviceId());
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
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        actions: [
          IconButton(
            icon: const Icon(Icons.casino_outlined, color: AppColors.primary),
            tooltip: 'Новый ID',
            onPressed: _advertising ? null : _newDeviceId,
          ),
          IconButton(
            icon: const Icon(Icons.save_outlined, color: AppColors.primary),
            tooltip: 'Сохранить',
            onPressed: _advertising ? null : _save,
          ),
          if (!widget.standalone)
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
                const Text('Метка'),
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
                StownCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SectionLabel('Имя метки'),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _nameCtrl,
                        enabled: !_advertising,
                        onChanged: (_) => setState(() {}),
                        style: const TextStyle(color: AppColors.onSurface),
                        decoration: const InputDecoration(
                          labelText: 'Имя',
                          prefixIcon: Icon(Icons.label_outline),
                          helperText:
                              'Видно в «Сканере» и шлюзе. До 12 символов.',
                          helperStyle: TextStyle(
                              color: AppColors.onSurfaceMuted, fontSize: 11),
                          helperMaxLines: 2,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const SectionLabel('Идентификатор'),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _idCtrl,
                        enabled: !_advertising,
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')),
                          LengthLimitingTextInputFormatter(14),
                        ],
                        onChanged: (_) => setState(() {}),
                        style: const TextStyle(
                          color: AppColors.onSurface,
                          fontFamily: 'monospace',
                          fontSize: 16,
                          letterSpacing: 1,
                        ),
                        decoration: InputDecoration(
                          labelText: 'ID',
                          prefixIcon: const Icon(Icons.fingerprint),
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.casino_outlined,
                                color: AppColors.primary),
                            tooltip: 'Случайный',
                            onPressed: _advertising ? null : _newDeviceId,
                          ),
                          helperText: '14 hex-символов (7 байт). Уникальный код метки.',
                          helperStyle: const TextStyle(
                              color: AppColors.onSurfaceMuted, fontSize: 11),
                          helperMaxLines: 2,
                        ),
                      ),
                    ],
                  ),
                ),
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
}
