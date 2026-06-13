import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/gateway.dart';
import '../services/gateway_monitor.dart';
import '../services/gateway_storage.dart';
import '../theme.dart';
import '../widgets/common.dart';

class GatewayScreen extends StatefulWidget {
  const GatewayScreen({super.key});

  @override
  State<GatewayScreen> createState() => _GatewayScreenState();
}

class _GatewayScreenState extends State<GatewayScreen> {
  GatewayConfig _config = GatewayConfig.defaults;
  late GatewayMonitor _monitor;
  StreamSubscription<GatewayEvent>? _eventSub;
  final List<GatewayEvent> _log = [];
  bool _running = false;
  bool _loaded = false;

  // Common
  final _rssiCtrl = TextEditingController();
  final _cooldownCtrl = TextEditingController();
  final _samplesCtrl = TextEditingController();

  // HTTP
  final _haUrlCtrl = TextEditingController();
  final _webhookCtrl = TextEditingController();

  // TCP
  final _tcpHostCtrl = TextEditingController();
  final _tcpPortCtrl = TextEditingController();

  // HM-10
  final _hm10Ctrl = TextEditingController();

  // Общий для TCP/HM-10: номер замка (hex)
  final _lockCtrl = TextEditingController();

  // Selected transport (mirror of config.transport for UI state)
  GatewayTransport _transport = GatewayTransport.http;

  @override
  void initState() {
    super.initState();
    _monitor = GatewayMonitor(config: _config);
    _eventSub = _monitor.events.listen(_onEvent);
    _load();
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _monitor.dispose();
    WakelockPlus.disable();
    _haUrlCtrl.dispose();
    _webhookCtrl.dispose();
    _rssiCtrl.dispose();
    _cooldownCtrl.dispose();
    _samplesCtrl.dispose();
    _tcpHostCtrl.dispose();
    _tcpPortCtrl.dispose();
    _hm10Ctrl.dispose();
    _lockCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final cfg = await GatewayStorage.instance.load();
    if (!mounted) return;
    setState(() {
      _config = cfg;
      _monitor.updateConfig(cfg);
      _transport = cfg.transport;
      _haUrlCtrl.text = cfg.haUrl;
      _webhookCtrl.text = cfg.webhookId;
      _rssiCtrl.text = cfg.rssiThreshold.toString();
      _cooldownCtrl.text = cfg.cooldownSeconds.toString();
      _samplesCtrl.text = cfg.samplesRequired.toString();
      _tcpHostCtrl.text = cfg.tcpHost;
      _tcpPortCtrl.text = cfg.tcpPort.toString();
      _hm10Ctrl.text = cfg.hm10Device;
      _lockCtrl.text = cfg.lockHex;
      _loaded = true;
    });
  }

  GatewayConfig _readForm() => _config.copyWith(
        rssiThreshold: int.tryParse(_rssiCtrl.text.trim()) ?? -65,
        cooldownSeconds: int.tryParse(_cooldownCtrl.text.trim()) ?? 10,
        samplesRequired: int.tryParse(_samplesCtrl.text.trim()) ?? 2,
        transport: _transport,
        haUrl: _haUrlCtrl.text.trim(),
        webhookId: _webhookCtrl.text.trim(),
        tcpHost: _tcpHostCtrl.text.trim(),
        tcpPort: int.tryParse(_tcpPortCtrl.text.trim()) ?? 9999,
        hm10Device: _hm10Ctrl.text.trim(),
        lockHex: _lockCtrl.text.trim().isEmpty ? '7702' : _lockCtrl.text.trim(),
      );

  Future<void> _saveConfig() async {
    final updated = _readForm();
    await GatewayStorage.instance.save(updated);
    if (!mounted) return;
    setState(() {
      _config = updated;
      _monitor.updateConfig(updated);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Настройки сохранены')),
    );
  }

  Future<bool> _ensurePermissions() async {
    final res = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    return res[Permission.bluetoothScan]?.isGranted == true &&
        res[Permission.bluetoothConnect]?.isGranted == true;
  }

  Future<void> _toggle() async {
    if (_running) {
      await _monitor.stop();
      await WakelockPlus.disable();
      setState(() => _running = false);
      return;
    }

    // Валидация перед стартом
    final cfg = _readForm();
    switch (cfg.transport) {
      case GatewayTransport.http:
        if (cfg.haUrl.isEmpty) {
          _snack('HTTP: заполните Home Assistant URL');
          return;
        }
        break;
      case GatewayTransport.tcp:
        if (cfg.tcpHost.isEmpty) {
          _snack('TCP: заполните хост');
          return;
        }
        break;
      case GatewayTransport.hm10:
        if (cfg.hm10Device.isEmpty) {
          _snack('HM-10: укажите адрес (MAC) модуля');
          return;
        }
        break;
    }
    if (cfg.whitelist.isEmpty) {
      _snack('Добавьте хотя бы одно авторизованное ТС');
      return;
    }
    if (!cfg.whitelist.any((v) => v.isValid)) {
      _snack('Каждое ТС должно иметь хотя бы один идентификатор '
          '(UUID/MAC/Major/Minor)');
      return;
    }

    await GatewayStorage.instance.save(cfg);
    setState(() => _config = cfg);
    _monitor.updateConfig(cfg);

    if (!await _ensurePermissions()) {
      _snack('Нужны разрешения Bluetooth');
      return;
    }

    await WakelockPlus.enable();
    await _monitor.start();
    if (mounted) setState(() => _running = true);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _onEvent(GatewayEvent e) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, e);
      if (_log.length > 100) _log.removeRange(100, _log.length);
    });
  }

  Color _eventColor(EventLevel l) => switch (l) {
        EventLevel.info => AppColors.onSurfaceMuted,
        EventLevel.success => AppColors.success,
        EventLevel.warning => const Color(0xFFFFB74D),
        EventLevel.error => AppColors.danger,
      };

  IconData _eventIcon(EventLevel l) => switch (l) {
        EventLevel.info => Icons.info_outline,
        EventLevel.success => Icons.check_circle_outline,
        EventLevel.warning => Icons.warning_amber_outlined,
        EventLevel.error => Icons.error_outline,
      };

  Future<void> _editVehicleDialog([AuthorizedVehicle? existing]) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final uuidCtrl = TextEditingController(text: existing?.uuid ?? '');
    final macCtrl = TextEditingController(text: existing?.macAddress ?? '');
    final majorCtrl = TextEditingController(
        text: existing?.major?.toString() ?? '');
    final minorCtrl = TextEditingController(
        text: existing?.minor?.toString() ?? '');
    final stownIdCtrl = TextEditingController(text: existing?.stownId ?? '');
    String? error;

    final result = await showDialog<Object?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: AppColors.surfaceElevated,
          title: Text(
            existing == null ? 'Новое ТС' : 'Редактировать «${existing.name}»',
            style: const TextStyle(color: AppColors.onSurface),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'OR-матчинг: заполните любые поля, по которым нужно опознавать ТС. '
                  'Хотя бы одно — обязательно.',
                  style: TextStyle(
                    color: AppColors.onSurfaceMuted,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  style: const TextStyle(color: AppColors.onSurface),
                  decoration: const InputDecoration(
                    labelText: 'Имя ТС',
                    prefixIcon: Icon(Icons.person_outline),
                    helperText: 'Отображается в журнале и в HA. Обязательно.',
                    helperStyle: TextStyle(
                        color: AppColors.onSurfaceMuted, fontSize: 11),
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: uuidCtrl,
                  style: const TextStyle(
                      color: AppColors.onSurface, fontFamily: 'monospace'),
                  decoration: const InputDecoration(
                    labelText: 'UUID',
                    prefixIcon: Icon(Icons.fingerprint),
                    helperText:
                        'Для iBeacon. С дефисами или без — нормализуется.',
                    helperStyle: TextStyle(
                        color: AppColors.onSurfaceMuted, fontSize: 11),
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: macCtrl,
                  style: const TextStyle(
                      color: AppColors.onSurface, fontFamily: 'monospace'),
                  decoration: const InputDecoration(
                    labelText: 'MAC-адрес',
                    prefixIcon: Icon(Icons.qr_code_2),
                    helperText:
                        'Стабилен только для ESP32/железа. На Android рандомизируется.',
                    helperStyle: TextStyle(
                        color: AppColors.onSurfaceMuted, fontSize: 11),
                    helperMaxLines: 3,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: majorCtrl,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(
                            color: AppColors.onSurface,
                            fontFamily: 'monospace'),
                        decoration: const InputDecoration(
                          labelText: 'Major',
                          prefixIcon: Icon(Icons.tag),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: minorCtrl,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(
                            color: AppColors.onSurface,
                            fontFamily: 'monospace'),
                        decoration: const InputDecoration(
                          labelText: 'Minor',
                          prefixIcon: Icon(Icons.tag),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: stownIdCtrl,
                  style: const TextStyle(
                      color: AppColors.onSurface, fontFamily: 'monospace'),
                  decoration: const InputDecoration(
                    labelText: 'STOWN ID',
                    prefixIcon: Icon(Icons.sensors),
                    helperText:
                        'Идентификатор STOWN-метки (14 hex). Скопируйте поле ID из вкладки «Сканер». Работает в любой обёртке.',
                    helperStyle: TextStyle(
                        color: AppColors.onSurfaceMuted, fontSize: 11),
                    helperMaxLines: 3,
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!,
                      style: const TextStyle(
                          color: AppColors.danger, fontSize: 12)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            if (existing != null)
              TextButton(
                onPressed: () => Navigator.pop(ctx, _Sentinel.deleted),
                child: const Text('Удалить',
                    style: TextStyle(color: AppColors.danger)),
              ),
            FilledButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) {
                  setLocal(() => error = 'Имя обязательно');
                  return;
                }
                final uuid = uuidCtrl.text.trim().isEmpty
                    ? null
                    : uuidCtrl.text.trim();
                final mac = macCtrl.text.trim().isEmpty
                    ? null
                    : macCtrl.text.trim();
                int? major;
                int? minor;
                if (majorCtrl.text.trim().isNotEmpty) {
                  major = int.tryParse(majorCtrl.text.trim());
                  if (major == null || major < 0 || major > 0xFFFF) {
                    setLocal(() => error = 'Major: число 0..65535');
                    return;
                  }
                }
                if (minorCtrl.text.trim().isNotEmpty) {
                  minor = int.tryParse(minorCtrl.text.trim());
                  if (minor == null || minor < 0 || minor > 0xFFFF) {
                    setLocal(() => error = 'Minor: число 0..65535');
                    return;
                  }
                }
                // UUID валидация — 32 hex
                if (uuid != null) {
                  final n = normalizeUuid(uuid);
                  if (n.length != 32 ||
                      !RegExp(r'^[0-9A-F]+$').hasMatch(n)) {
                    setLocal(() => error = 'UUID: 32 hex-символа');
                    return;
                  }
                }
                // MAC валидация — 12 hex
                if (mac != null) {
                  final n = normalizeMac(mac);
                  if (n.length != 12 ||
                      !RegExp(r'^[0-9A-F]+$').hasMatch(n)) {
                    setLocal(() => error = 'MAC: 12 hex (напр AA:BB:CC:DD:EE:FF)');
                    return;
                  }
                }
                final stownId = stownIdCtrl.text.trim().isEmpty
                    ? null
                    : stownIdCtrl.text.trim();
                if (stownId != null) {
                  final n = normalizeId(stownId);
                  if (n.length != 14 ||
                      !RegExp(r'^[0-9A-F]+$').hasMatch(n)) {
                    setLocal(() => error = 'STOWN ID: 14 hex-символов (7 байт)');
                    return;
                  }
                }
                if (uuid == null &&
                    mac == null &&
                    major == null &&
                    minor == null &&
                    stownId == null) {
                  setLocal(() => error =
                      'Заполните хотя бы один идентификатор: UUID, MAC, Major, Minor или STOWN ID');
                  return;
                }
                Navigator.pop(
                  ctx,
                  AuthorizedVehicle(
                    name: name,
                    uuid: uuid,
                    macAddress: mac,
                    major: major,
                    minor: minor,
                    stownId: stownId,
                  ),
                );
              },
              style: FilledButton.styleFrom(minimumSize: const Size(80, 40)),
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );

    if (result == null) return;
    final newList = List<AuthorizedVehicle>.from(_config.whitelist);
    if (existing != null) {
      newList.remove(existing);
    }
    if (result is AuthorizedVehicle) {
      newList.add(result);
    }
    final updated = _config.copyWith(whitelist: newList);
    await GatewayStorage.instance.save(updated);
    if (!mounted) return;
    setState(() {
      _config = updated;
      _monitor.updateConfig(updated);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        actions: [
          IconButton(
            icon: const Icon(Icons.save_outlined, color: AppColors.primary),
            tooltip: 'Сохранить настройки',
            onPressed: _running ? null : _saveConfig,
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: AppColors.primary),
            tooltip: 'Выйти',
            onPressed: () => performLogout(
              context,
              onBeforeLogout: () async {
                if (_running) {
                  await _monitor.stop();
                  await WakelockPlus.disable();
                }
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
                color: _running ? AppColors.success : AppColors.onSurfaceMuted,
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Шлюз'),
                Text(
                  _running ? 'Мониторинг активен' : 'Остановлен',
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
                _settingsCard(),
                const SizedBox(height: 12),
                _vehiclesCard(),
                const SizedBox(height: 12),
                _logCard(),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: PrimaryGradientButton(
                label: _running
                    ? 'Остановить мониторинг'
                    : 'Запустить мониторинг',
                icon: _running ? Icons.stop : Icons.play_arrow,
                onPressed: _toggle,
                color: _running ? AppColors.danger : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _settingsCard() {
    return StownCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionHeader(
            icon: Icons.settings_outlined,
            text: 'Настройки',
          ),
          const SizedBox(height: 12),

          // ---- Transport selector ----
          const Text(
            'ТРАНСПОРТ',
            style: TextStyle(
              color: AppColors.onSurfaceMuted,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 6),
          _transportSelector(),
          const SizedBox(height: 12),

          // ---- Transport-specific fields ----
          ..._transportFields(),

          const SizedBox(height: 8),
          const Divider(color: AppColors.divider, height: 1),
          const SizedBox(height: 12),

          // ---- Common fields ----
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _textField(
                  _rssiCtrl,
                  'RSSI',
                  hint: '-65 dBm ≈ 5–10 м',
                  numeric: true,
                  allowNegative: true,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _textField(
                  _cooldownCtrl,
                  'Cooldown',
                  hint: 'сек до повтора',
                  numeric: true,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _textField(
                  _samplesCtrl,
                  'Samples',
                  hint: 'для anti-flicker',
                  numeric: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _transportSelector() {
    Widget tab(GatewayTransport t, String label, IconData icon) {
      final selected = _transport == t;
      return Expanded(
        child: GestureDetector(
          onTap: _running ? null : () => setState(() => _transport = t),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            margin: const EdgeInsets.all(4),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              gradient: selected ? primaryGradient : null,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  color:
                      selected ? Colors.white : AppColors.onSurfaceMuted,
                  size: 18,
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    color: selected
                        ? Colors.white
                        : AppColors.onSurfaceMuted,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceDim,
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        children: [
          tab(GatewayTransport.http, 'HTTP', Icons.http),
          tab(GatewayTransport.tcp, 'TCP', Icons.electrical_services),
          tab(GatewayTransport.hm10, 'HM-10', Icons.bluetooth),
        ],
      ),
    );
  }

  List<Widget> _transportFields() {
    switch (_transport) {
      case GatewayTransport.http:
        return [
          _textField(
            _haUrlCtrl,
            'Адрес HA',
            hint: 'Локальный адрес Home Assistant, напр. http://192.168.0.10:8123',
            icon: Icons.home_outlined,
          ),
          const SizedBox(height: 12),
          _textField(
            _webhookCtrl,
            'Webhook ID',
            hint: 'Имя webhook в HA. Полный URL: '
                '$_haUrlPreview/api/webhook/${_webhookCtrl.text}',
            icon: Icons.link,
          ),
        ];
      case GatewayTransport.tcp:
        return [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              flex: 2,
              child: _textField(
                _tcpHostCtrl,
                'TCP хост',
                hint: 'IP или DNS контроллера',
                icon: Icons.dns_outlined,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _textField(
                _tcpPortCtrl,
                'Порт',
                hint: 'напр. 9999',
                numeric: true,
              ),
            ),
          ]),
          const SizedBox(height: 12),
          _lockField(),
          const SizedBox(height: 8),
          _commandsHint(),
        ];
      case GatewayTransport.hm10:
        return [
          _textField(
            _hm10Ctrl,
            'HM-10 адрес (MAC)',
            hint: 'MAC модуля, напр. E0:E5:CF:A2:BB:46. Скопируйте из «Сканера».',
            icon: Icons.bluetooth,
          ),
          const SizedBox(height: 12),
          _lockField(),
          const SizedBox(height: 8),
          _commandsHint(),
        ];
    }
  }

  Widget _lockField() => _textField(
        _lockCtrl,
        'Номер замка (hex)',
        hint: 'Идёт в 10-байтный пакет. Напр. 7702',
        icon: Icons.lock_outline,
      );

  Widget _commandsHint() => const Text(
        'Открытие отправляет две команды: сначала пакет с 0x01, через 500 мс — '
        'с 0x87. Идентификатор берётся из STOWN-метки (иначе нули).',
        style: TextStyle(
          color: AppColors.onSurfaceMuted,
          fontSize: 11,
          height: 1.4,
        ),
      );

  String get _haUrlPreview {
    final url = _haUrlCtrl.text.trim();
    if (url.isEmpty) return 'http://HA';
    return url.replaceAll(RegExp(r'/+$'), '');
  }

  Widget _vehiclesCard() {
    return StownCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: _SectionHeader(
                  icon: Icons.directions_car,
                  text: 'Авторизованные ТС',
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add_circle_outline,
                    color: AppColors.primary),
                tooltip: 'Добавить',
                onPressed: _running ? null : () => _editVehicleDialog(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_config.whitelist.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Пусто — добавьте хотя бы одно ТС',
                style: TextStyle(color: AppColors.onSurfaceMuted),
              ),
            )
          else
            ..._config.whitelist.map((v) => _vehicleTile(v)),
        ],
      ),
    );
  }

  Widget _vehicleTile(AuthorizedVehicle v) {
    return InkWell(
      onTap: _running ? null : () => _editVehicleDialog(v),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.directions_car,
                  color: AppColors.primary, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    v.name,
                    style: const TextStyle(
                      color: AppColors.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    v.summary,
                    style: const TextStyle(
                      color: AppColors.onSurfaceMuted,
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              _running ? Icons.lock : Icons.edit_outlined,
              color: AppColors.onSurfaceMuted,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }

  Widget _logCard() {
    return StownCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: _SectionHeader(
                  icon: Icons.list_alt,
                  text: 'Журнал событий',
                ),
              ),
              if (_log.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.clear_all,
                      color: AppColors.onSurfaceMuted),
                  tooltip: 'Очистить',
                  onPressed: () => setState(_log.clear),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_log.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Здесь будут события после запуска мониторинга',
                style: TextStyle(color: AppColors.onSurfaceMuted),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _log.length,
                itemBuilder: (_, i) => _logRow(_log[i]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _logRow(GatewayEvent e) {
    final time =
        '${e.timestamp.hour.toString().padLeft(2, '0')}:${e.timestamp.minute.toString().padLeft(2, '0')}:${e.timestamp.second.toString().padLeft(2, '0')}';
    final color = _eventColor(e.level);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_eventIcon(e.level), color: color, size: 16),
          const SizedBox(width: 8),
          Text(
            time,
            style: const TextStyle(
              color: AppColors.onSurfaceMuted,
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              e.message,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _textField(
    TextEditingController c,
    String label, {
    String? hint,
    IconData? icon,
    bool numeric = false,
    bool allowNegative = false,
  }) {
    return TextField(
      controller: c,
      enabled: !_running,
      style: const TextStyle(
        color: AppColors.onSurface,
        fontFamily: 'monospace',
        fontSize: 13,
      ),
      keyboardType: numeric
          ? TextInputType.numberWithOptions(signed: allowNegative)
          : TextInputType.text,
      inputFormatters: numeric
          ? [
              FilteringTextInputFormatter.allow(
                allowNegative ? RegExp(r'^-?\d*') : RegExp(r'^\d*'),
              ),
            ]
          : null,
      onChanged: (_) {
        if (c == _haUrlCtrl || c == _webhookCtrl) {
          setState(() {});
        }
      },
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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppColors.primary, size: 18),
        const SizedBox(width: 8),
        Text(
          text.toUpperCase(),
          style: const TextStyle(
            color: AppColors.onSurface,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.0,
          ),
        ),
      ],
    );
  }
}

enum _Sentinel { deleted }
