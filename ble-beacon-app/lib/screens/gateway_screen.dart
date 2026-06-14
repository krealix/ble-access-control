import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/gateway.dart';
import '../services/beacon_parser.dart';
import '../services/gateway_foreground.dart';
import '../services/gateway_logger.dart';
import '../services/gateway_monitor.dart';
import '../services/gateway_storage.dart';
import '../services/hm10_sender.dart';
import '../services/incoming_call.dart';
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

  // Алгоритм определения открытия: 'deadZone' | 'trajectory'
  String _decisionMode = 'deadZone';

  // «Мёртвая зона» (гистерезис) + cooldown для звонков
  final _rssiNearCtrl = TextEditingController(); // P_close
  final _rssiFarCtrl = TextEditingController(); // P_dist
  final _tCloseCtrl = TextEditingController(); // t_close, сек
  final _tFarCtrl = TextEditingController(); // t_dist, сек
  final _cooldownCtrl = TextEditingController(); // антидребезг звонков, сек

  // «Траектория» (Калман + лог-дистанция + тренд)
  final _grantDistCtrl = TextEditingController(); // радиус зоны доступа, м
  final _approachCtrl = TextEditingController(); // проб «приближается» подряд
  final _trendEpsCtrl = TextEditingController(); // порог наклона RSSI, dBm/с
  final _txPowerCtrl = TextEditingController(); // RSSI на 1 м
  final _pathLossCtrl = TextEditingController(); // показатель затухания n

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

  // Обновление «живого статуса» меток во время работы
  Timer? _liveTimer;

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
    _liveTimer?.cancel();
    _monitor.dispose();
    WakelockPlus.disable();
    _haUrlCtrl.dispose();
    _webhookCtrl.dispose();
    _rssiNearCtrl.dispose();
    _rssiFarCtrl.dispose();
    _tCloseCtrl.dispose();
    _tFarCtrl.dispose();
    _cooldownCtrl.dispose();
    _tcpHostCtrl.dispose();
    _tcpPortCtrl.dispose();
    _hm10Ctrl.dispose();
    _lockCtrl.dispose();
    _grantDistCtrl.dispose();
    _approachCtrl.dispose();
    _trendEpsCtrl.dispose();
    _txPowerCtrl.dispose();
    _pathLossCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final cfg = await GatewayStorage.instance.load();
    if (!mounted) return;
    setState(() {
      _config = cfg;
      _monitor.updateConfig(cfg);
      _transport = cfg.transport;
      _decisionMode = cfg.decisionMode;
      _haUrlCtrl.text = cfg.haUrl;
      _webhookCtrl.text = cfg.webhookId;
      _rssiNearCtrl.text = cfg.rssiNear.toString();
      _rssiFarCtrl.text = cfg.rssiFar.toString();
      _tCloseCtrl.text = (cfg.tCloseMs ~/ 1000).toString();
      _tFarCtrl.text = (cfg.tFarMs ~/ 1000).toString();
      _cooldownCtrl.text = cfg.cooldownSeconds.toString();
      _tcpHostCtrl.text = cfg.tcpHost;
      _tcpPortCtrl.text = cfg.tcpPort.toString();
      _hm10Ctrl.text = cfg.hm10Device;
      _lockCtrl.text = cfg.lockHex;
      _grantDistCtrl.text = _fmtNum(cfg.grantDistance);
      _approachCtrl.text = cfg.approachSamples.toString();
      _trendEpsCtrl.text = _fmtNum(cfg.trendEps);
      _txPowerCtrl.text = _fmtNum(cfg.txPower1m);
      _pathLossCtrl.text = _fmtNum(cfg.pathLossN);
      _loaded = true;
    });
  }

  GatewayConfig _readForm() => _config.copyWith(
        decisionMode: _decisionMode,
        rssiNear: int.tryParse(_rssiNearCtrl.text.trim()) ?? -60,
        rssiFar: int.tryParse(_rssiFarCtrl.text.trim()) ?? -80,
        tCloseMs: (int.tryParse(_tCloseCtrl.text.trim()) ?? 1) * 1000,
        tFarMs: (int.tryParse(_tFarCtrl.text.trim()) ?? 3) * 1000,
        cooldownSeconds: int.tryParse(_cooldownCtrl.text.trim()) ?? 10,
        grantDistance: double.tryParse(_grantDistCtrl.text.trim()) ?? 2.0,
        approachSamples: int.tryParse(_approachCtrl.text.trim()) ?? 4,
        trendEps: double.tryParse(_trendEpsCtrl.text.trim()) ?? 0.2,
        txPower1m: double.tryParse(_txPowerCtrl.text.trim()) ?? -59.0,
        pathLossN: double.tryParse(_pathLossCtrl.text.trim()) ?? 2.5,
        transport: _transport,
        haUrl: _haUrlCtrl.text.trim(),
        webhookId: _webhookCtrl.text.trim(),
        tcpHost: _tcpHostCtrl.text.trim(),
        tcpPort: int.tryParse(_tcpPortCtrl.text.trim()) ?? 9999,
        hm10Device: _hm10Ctrl.text.trim(),
        lockHex: _lockCtrl.text.trim().isEmpty ? '7702' : _lockCtrl.text.trim(),
      );

  /// Форматирует число без лишнего «.0» (для префилла полей).
  String _fmtNum(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

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
      await GatewayForeground.stop();
      await WakelockPlus.disable();
      _liveTimer?.cancel();
      _liveTimer = null;
      setState(() => _running = false);
      return;
    }

    // Подтягиваем актуальный белый список из хранилища — он мог измениться
    // во вкладке «Сканер» (добавление ТС без перезапуска приложения).
    try {
      final stored = await GatewayStorage.instance.load();
      _config = _config.copyWith(whitelist: stored.whitelist);
    } catch (_) {}

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
    // Разрешение на уведомление (Android 13+) — для foreground-сервиса.
    await Permission.notification.request();

    await WakelockPlus.enable();
    await GatewayForeground.start(); // фоновая работа с погашенным экраном
    await _monitor.start();
    _liveTimer = Timer.periodic(
        const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
    if (mounted) setState(() => _running = true);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Экспорт CSV-лога проездов/RSSI (поделиться файлом).
  Future<void> _exportLog() async {
    try {
      final size = await GatewayLogger.instance.sizeBytes();
      if (size <= 40) {
        _snack('Лог пуст');
        return;
      }
      final path = await GatewayLogger.instance.fileForExport();
      await Share.shareXFiles([XFile(path)], subject: 'Журнал шлюза BLE');
    } catch (e) {
      _snack('Экспорт: $e');
    }
  }

  Future<void> _clearLogFile() async {
    await GatewayLogger.instance.clear();
    _snack('Лог-файл очищен');
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

  /// Диалог добавления/редактирования ТС.
  /// [existing] — редактирование существующего (с кнопкой «Удалить»).
  /// [template] — префилл полей для нового ТС (например, из встроенного скана).
  Future<void> _editVehicleDialog(
      [AuthorizedVehicle? existing, AuthorizedVehicle? template]) async {
    final src = existing ?? template;
    final nameCtrl = TextEditingController(text: src?.name ?? '');
    final uuidCtrl = TextEditingController(text: src?.uuid ?? '');
    final macCtrl = TextEditingController(text: src?.macAddress ?? '');
    final majorCtrl =
        TextEditingController(text: src?.major?.toString() ?? '');
    final minorCtrl =
        TextEditingController(text: src?.minor?.toString() ?? '');
    final stownIdCtrl = TextEditingController(text: src?.stownId ?? '');
    // Телефон для доступа по звонку: префилл из matchKey "PHONE:..." если есть.
    final phoneCtrl = TextEditingController(
      text: (src?.matchKey ?? '').startsWith('PHONE:')
          ? src!.matchKey!.substring('PHONE:'.length)
          : '',
    );
    final secretCtrl = TextEditingController(text: src?.secret ?? '');
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
                    labelText: 'ID метки',
                    prefixIcon: Icon(Icons.sensors),
                    helperText:
                        'Идентификатор метки (14 hex). Скопируйте поле ID из вкладки «Сканер». Работает в любой обёртке.',
                    helperStyle: TextStyle(
                        color: AppColors.onSurfaceMuted, fontSize: 11),
                    helperMaxLines: 3,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: phoneCtrl,
                  keyboardType: TextInputType.phone,
                  style: const TextStyle(
                      color: AppColors.onSurface, fontFamily: 'monospace'),
                  decoration: const InputDecoration(
                    labelText: 'Телефон',
                    prefixIcon: Icon(Icons.phone_outlined),
                    helperText:
                        'Доступ по звонку: открытие при входящем с этого номера. Сверка по последним 10 цифрам.',
                    helperStyle: TextStyle(
                        color: AppColors.onSurfaceMuted, fontSize: 11),
                    helperMaxLines: 3,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: secretCtrl,
                  textCapitalization: TextCapitalization.characters,
                  style: const TextStyle(
                      color: AppColors.onSurface, fontFamily: 'monospace'),
                  decoration: const InputDecoration(
                    labelText: 'Секрет (rolling)',
                    prefixIcon: Icon(Icons.key_outlined),
                    helperText:
                        'Для динамической метки: тот же секрет (hex), что в метке. Опознаёт меняющийся код.',
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
                    setLocal(() => error = 'ID метки: 14 hex-символов (7 байт)');
                    return;
                  }
                }
                // Телефон → ключ PHONE:<последние 10 цифр>. Если поле пустое —
                // сохраняем прежний matchKey (например, STOWN:/MAC из «Сканера»).
                final phoneDigits = normalizePhone(phoneCtrl.text);
                final matchKey = phoneDigits.isNotEmpty
                    ? 'PHONE:$phoneDigits'
                    : ((existing?.matchKey ?? '').startsWith('PHONE:')
                        ? null
                        : existing?.matchKey);
                final secret = secretCtrl.text.trim().isEmpty
                    ? null
                    : secretCtrl.text.trim().toUpperCase();
                if (secret != null &&
                    secret.replaceAll(RegExp('[^0-9A-F]'), '').length < 8) {
                  setLocal(() => error = 'Секрет: минимум 8 hex-символов');
                  return;
                }
                if (uuid == null &&
                    mac == null &&
                    major == null &&
                    minor == null &&
                    stownId == null &&
                    (matchKey == null || matchKey.isEmpty) &&
                    secret == null) {
                  setLocal(() => error =
                      'Заполните хотя бы один идентификатор: UUID, MAC, Major, Minor, ID метки, Телефон или Секрет');
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
                    matchKey: matchKey,
                    secret: secret,
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
                if (_running) ...[
                  _liveStatusCard(),
                  const SizedBox(height: 12),
                ],
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


  /// Живой статус авторизованных меток: зона, RSSI, давность контакта.
  Widget _liveStatusCard() {
    final snap = _monitor.liveSnapshot();
    final now = DateTime.now();
    return StownCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: _SectionHeader(icon: Icons.radar, text: 'Живой статус'),
              ),
              if (_transport == GatewayTransport.hm10) _hm10IndicatorChip(),
            ],
          ),
          const SizedBox(height: 8),
          if (snap.isEmpty)
            const Text('Меток в зоне нет…',
                style: TextStyle(color: AppColors.onSurfaceMuted))
          else
            ...snap.entries.map((e) => _liveRow(e.key, e.value, now)),
        ],
      ),
    );
  }

  Widget _liveRow(String name, TagLive live, DateTime now) {
    final near = live.zone == 'near';
    final ago = now.difference(live.lastSeen).inSeconds;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: near ? AppColors.success : AppColors.onSurfaceMuted,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppColors.onSurface, fontWeight: FontWeight.w600)),
          ),
          Text(near ? 'рядом' : 'далеко',
              style: TextStyle(
                  color: near ? AppColors.success : AppColors.onSurfaceMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
          const SizedBox(width: 10),
          SizedBox(
            width: 46,
            child: Text('${live.rssi}',
                textAlign: TextAlign.end,
                style: const TextStyle(
                    color: AppColors.onSurface,
                    fontFamily: 'monospace',
                    fontSize: 13)),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 44,
            child: Text(ago <= 1 ? 'сейчас' : '$ago с',
                textAlign: TextAlign.end,
                style: const TextStyle(
                    color: AppColors.onSurfaceMuted, fontSize: 11)),
          ),
        ],
      ),
    );
  }

  /// Индикатор постоянного подключения к HM-10.
  Widget _hm10IndicatorChip() {
    return ValueListenableBuilder<bool>(
      valueListenable: Hm10Sender.instance.connected,
      builder: (_, conn, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(conn ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
              size: 16, color: conn ? AppColors.success : AppColors.danger),
          const SizedBox(width: 4),
          Text(conn ? 'HM-10 ✓' : 'HM-10 ✕',
              style: TextStyle(
                  color: conn ? AppColors.success : AppColors.onSurfaceMuted,
                  fontSize: 12)),
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

          // ---- Алгоритм определения открытия (BLE) ----
          const Text(
            'АЛГОРИТМ ОТКРЫТИЯ (BLE)',
            style: TextStyle(
              color: AppColors.onSurfaceMuted,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 6),
          _modeSelector(),
          const SizedBox(height: 12),
          if (_decisionMode == 'trajectory')
            ..._trajectoryFields()
          else
            ..._deadZoneFields(),
          const SizedBox(height: 12),
          _textField(_cooldownCtrl, 'Антидребезг звонка, с',
              hint: 'Мин. интервал между открытиями по входящему звонку.',
              icon: Icons.call_outlined,
              numeric: true),
        ],
      ),
    );
  }

  /// Переключатель алгоритма: «Мёртвая зона» ↔ «Траектория».
  Widget _modeSelector() {
    Widget tab(String mode, String label, IconData icon) {
      final selected = _decisionMode == mode;
      return Expanded(
        child: GestureDetector(
          onTap: _running ? null : () => setState(() => _decisionMode = mode),
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
                Icon(icon,
                    color: selected ? Colors.white : AppColors.onSurfaceMuted,
                    size: 18),
                const SizedBox(height: 2),
                Text(label,
                    style: TextStyle(
                      color:
                          selected ? Colors.white : AppColors.onSurfaceMuted,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    )),
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
          tab('deadZone', 'Мёртвая зона', Icons.adjust),
          tab('trajectory', 'Траектория', Icons.timeline),
        ],
      ),
    );
  }

  /// Поля алгоритма «мёртвой зоны» (гистерезис по двум порогам RSSI).
  List<Widget> _deadZoneFields() => [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _textField(
                _rssiNearCtrl,
                'RSSI рядом',
                hint: 'P_close, напр. -60',
                numeric: true,
                allowNegative: true,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _textField(
                _rssiFarCtrl,
                'RSSI далеко',
                hint: 'P_dist, напр. -80',
                numeric: true,
                allowNegative: true,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _textField(_tCloseCtrl, 't рядом, с',
                  hint: 'держать', numeric: true),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _textField(_tFarCtrl, 't далеко, с',
                  hint: 'перевзвод', numeric: true),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Открытие — когда метка подошла ближе «RSSI рядом» на «t рядом». '
          'Повторно — только после отдаления за «RSSI далеко» на «t далеко» '
          'или пропадания из зоны.',
          style: TextStyle(
            color: AppColors.onSurfaceMuted,
            fontSize: 11,
            height: 1.4,
          ),
        ),
      ];

  /// Поля алгоритма «траектория» (Калман → лог-дистанция → тренд → КА).
  List<Widget> _trajectoryFields() => [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _textField(_grantDistCtrl, 'Зона доступа, м',
                  hint: 'радиус', numeric: true, decimal: true),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _textField(_approachCtrl, 'Проб подряд',
                  hint: 'приближается', numeric: true),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _textField(_trendEpsCtrl, 'Порог тренда',
                  hint: 'dBm/с', numeric: true, decimal: true),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _textField(_txPowerCtrl, 'RSSI на 1 м',
                  hint: 'калибровка',
                  numeric: true,
                  decimal: true,
                  allowNegative: true),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _textField(_pathLossCtrl, 'Затухание n',
                  hint: 'среда 2..4', numeric: true, decimal: true),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'RSSI сглаживается фильтром Калмана и переводится в дистанцию по '
          'лог-дистанционной модели. Доступ выдаётся при устойчивом приближении '
          '(тренд по МНК) и входе в «зону доступа». Ядро методики ВКР.',
          style: TextStyle(
            color: AppColors.onSurfaceMuted,
            fontSize: 11,
            height: 1.4,
          ),
        ),
      ];

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
            hint: 'MAC модуля. Нажмите «Найти» или скопируйте из «Сканера».',
            icon: Icons.bluetooth,
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _running ? null : _pickHm10,
              icon: const Icon(Icons.bluetooth_searching, size: 18),
              label: const Text('Найти HM-10'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: const BorderSide(color: AppColors.divider),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _lockField(),
          const SizedBox(height: 8),
          _commandsHint(),
        ];
    }
  }

  /// Сканирует эфир и даёт выбрать HM-10 из списка (как в «Сканере») —
  /// без ручного ввода MAC. Подставляет remoteId в поле адреса.
  Future<void> _pickHm10() async {
    if (_running) return;
    if (!await _ensurePermissions()) {
      _snack('Нужны разрешения Bluetooth');
      return;
    }

    final results = <ScanResult>[];
    StreamSubscription<List<ScanResult>>? sub;
    try {
      await Hm10Sender.instance.startScan(timeout: const Duration(seconds: 12));
    } catch (e) {
      _snack('Скан: $e');
      return;
    }
    if (!mounted) {
      await Hm10Sender.instance.stopScan();
      return;
    }

    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          sub ??= Hm10Sender.instance.scanResults.listen((rs) {
            results
              ..clear()
              ..addAll(rs);
            results.sort((a, b) {
              final ah = Hm10Sender.looksLikeHm10(a) ? 0 : 1;
              final bh = Hm10Sender.looksLikeHm10(b) ? 0 : 1;
              if (ah != bh) return ah - bh;
              return b.rssi.compareTo(a.rssi);
            });
            setSheet(() {});
          });
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text('Выберите HM-10',
                            style: TextStyle(
                                color: AppColors.onSurface,
                                fontSize: 16,
                                fontWeight: FontWeight.w700)),
                      ),
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (results.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text('Поиск устройств рядом…',
                          style: TextStyle(color: AppColors.onSurfaceMuted)),
                    )
                  else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 360),
                      child: ListView(
                        shrinkWrap: true,
                        children: results.map((r) {
                          final isHm = Hm10Sender.looksLikeHm10(r);
                          final name = r.advertisementData.advName.isEmpty
                              ? '(без имени)'
                              : r.advertisementData.advName;
                          return ListTile(
                            leading: Icon(
                              isHm ? Icons.sensors : Icons.bluetooth,
                              color: isHm
                                  ? AppColors.primary
                                  : AppColors.onSurfaceMuted,
                            ),
                            title: Text(name,
                                style: TextStyle(
                                  color: AppColors.onSurface,
                                  fontWeight:
                                      isHm ? FontWeight.w700 : FontWeight.w500,
                                )),
                            subtitle: Text(r.device.remoteId.str,
                                style: const TextStyle(
                                    color: AppColors.onSurfaceMuted,
                                    fontFamily: 'monospace',
                                    fontSize: 12)),
                            trailing: Text('${r.rssi}',
                                style: const TextStyle(
                                    color: AppColors.onSurfaceMuted,
                                    fontSize: 12)),
                            onTap: () =>
                                Navigator.pop(ctx, r.device.remoteId.str),
                          );
                        }).toList(),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );

    await sub?.cancel();
    await Hm10Sender.instance.stopScan();
    if (picked != null && mounted) {
      setState(() => _hm10Ctrl.text = picked.toUpperCase());
    }
  }

  /// Встроенный скан: ищет метки рядом и открывает диалог добавления с
  /// предзаполненными полями (STOWN ID / iBeacon / MAC) — без вкладки «Сканер».
  Future<void> _scanAddVehicle() async {
    if (_running) return;
    if (!await _ensurePermissions()) {
      _snack('Нужны разрешения Bluetooth');
      return;
    }

    final results = <ScanResult>[];
    StreamSubscription<List<ScanResult>>? sub;
    try {
      await Hm10Sender.instance.startScan(timeout: const Duration(seconds: 12));
    } catch (e) {
      _snack('Скан: $e');
      return;
    }
    if (!mounted) {
      await Hm10Sender.instance.stopScan();
      return;
    }

    final picked = await showModalBottomSheet<ScanResult>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          sub ??= Hm10Sender.instance.scanResults.listen((rs) {
            results
              ..clear()
              ..addAll(rs);
            // Сначала STOWN-метки, затем по убыванию RSSI.
            results.sort((a, b) {
              final ai = stownIdFromAdv(a.advertisementData) != null ? 0 : 1;
              final bi = stownIdFromAdv(b.advertisementData) != null ? 0 : 1;
              if (ai != bi) return ai - bi;
              return b.rssi.compareTo(a.rssi);
            });
            setSheet(() {});
          });
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text('Метки и устройства рядом',
                            style: TextStyle(
                                color: AppColors.onSurface,
                                fontSize: 16,
                                fontWeight: FontWeight.w700)),
                      ),
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (results.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text('Поиск устройств рядом…',
                          style: TextStyle(color: AppColors.onSurfaceMuted)),
                    )
                  else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 360),
                      child: ListView(
                        shrinkWrap: true,
                        children: results.map((r) {
                          final stownId =
                              stownIdFromAdv(r.advertisementData);
                          final isTag = stownId != null;
                          final advName = r.advertisementData.advName;
                          final title = advName.isEmpty
                              ? (isTag ? 'Метка' : '(без имени)')
                              : advName;
                          final subtitle = isTag
                              ? 'ID $stownId'
                              : r.device.remoteId.str;
                          return ListTile(
                            leading: Icon(
                              isTag ? Icons.sensors : Icons.bluetooth,
                              color: isTag
                                  ? AppColors.primary
                                  : AppColors.onSurfaceMuted,
                            ),
                            title: Text(title,
                                style: TextStyle(
                                  color: AppColors.onSurface,
                                  fontWeight: isTag
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                )),
                            subtitle: Text(subtitle,
                                style: const TextStyle(
                                    color: AppColors.onSurfaceMuted,
                                    fontFamily: 'monospace',
                                    fontSize: 12)),
                            trailing: Text('${r.rssi}',
                                style: const TextStyle(
                                    color: AppColors.onSurfaceMuted,
                                    fontSize: 12)),
                            onTap: () => Navigator.pop(ctx, r),
                          );
                        }).toList(),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );

    await sub?.cancel();
    await Hm10Sender.instance.stopScan();
    if (picked == null || !mounted) return;
    await _editVehicleDialog(null, _templateFromScan(picked));
  }

  /// Строит шаблон ТС из результата скана: STOWN ID, либо iBeacon (UUID/Major/
  /// Minor), либо MAC. Имя — из advName, иначе из MAC.
  AuthorizedVehicle _templateFromScan(ScanResult r) {
    final adv = r.advertisementData;
    final mac = r.device.remoteId.str;
    final advName = adv.advName.trim();

    final stownId = stownIdFromAdv(adv);

    String? uuid;
    int? major;
    int? minor;
    final apple = adv.manufacturerData[0x004C];
    if (apple != null &&
        apple.length >= 23 &&
        apple[0] == 0x02 &&
        apple[1] == 0x15) {
      uuid = apple
          .sublist(2, 18)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join()
          .toUpperCase();
      major = (apple[18] << 8) | apple[19];
      minor = (apple[20] << 8) | apple[21];
    }

    final fallbackName = mac.length >= 5 ? 'Метка ${mac.substring(0, 5)}' : 'Метка';
    return AuthorizedVehicle(
      name: advName.isNotEmpty ? advName : fallbackName,
      uuid: uuid,
      // Для STOWN-метки и iBeacon MAC не сохраняем (рандомизируется на Android).
      macAddress: (stownId == null && uuid == null) ? mac : null,
      major: major,
      minor: minor,
      stownId: stownId,
    );
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

  /// Перечитывает белый список из хранилища (метки, добавленные во вкладке
  /// «Сканер») и применяет к работающему монитору — без перезапуска приложения.
  Future<void> _reloadWhitelist() async {
    final stored = await GatewayStorage.instance.load();
    if (!mounted) return;
    setState(() => _config = _config.copyWith(whitelist: stored.whitelist));
    if (_running) _monitor.updateConfig(_readForm());
    _snack('Список ТС обновлён: ${stored.whitelist.length}');
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
                icon: const Icon(Icons.refresh, color: AppColors.primary),
                tooltip: 'Обновить из «Сканера»',
                onPressed: _reloadWhitelist,
              ),
              IconButton(
                icon: const Icon(Icons.bluetooth_searching,
                    color: AppColors.primary),
                tooltip: 'Найти метку рядом',
                onPressed: _running ? null : _scanAddVehicle,
              ),
              IconButton(
                icon: const Icon(Icons.add_circle_outline,
                    color: AppColors.primary),
                tooltip: 'Добавить вручную',
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
              IconButton(
                icon: const Icon(Icons.ios_share, color: AppColors.primary),
                tooltip: 'Экспорт лога (CSV)',
                onPressed: _exportLog,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline,
                    color: AppColors.onSurfaceMuted),
                tooltip: 'Очистить лог-файл',
                onPressed: _clearLogFile,
              ),
              if (_log.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.clear_all,
                      color: AppColors.onSurfaceMuted),
                  tooltip: 'Очистить экран',
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
    bool decimal = false,
  }) {
    final numRe = decimal
        ? (allowNegative ? RegExp(r'^-?\d*\.?\d*') : RegExp(r'^\d*\.?\d*'))
        : (allowNegative ? RegExp(r'^-?\d*') : RegExp(r'^\d*'));
    return TextField(
      controller: c,
      enabled: !_running,
      style: const TextStyle(
        color: AppColors.onSurface,
        fontFamily: 'monospace',
        fontSize: 13,
      ),
      keyboardType: numeric
          ? TextInputType.numberWithOptions(
              signed: allowNegative, decimal: decimal)
          : TextInputType.text,
      inputFormatters: numeric
          ? [FilteringTextInputFormatter.allow(numRe)]
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
