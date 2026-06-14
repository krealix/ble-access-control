import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import '../models/beacon.dart';
import '../models/gateway.dart';
import '../services/beacon_parser.dart';
import '../services/gateway_storage.dart';
import '../services/scanner_logger.dart';
import '../theme.dart';
import '../widgets/common.dart';

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  final Map<String, ParsedBeacon> _beacons = {};
  StreamSubscription<List<ScanResult>>? _resultsSub;
  bool _scanning = false; // активная сессия поиска (намерение пользователя)
  BeaconKind? _filter;

  // Логирование наблюдений (время/метка/расстояние) в отдельный файл.
  bool _logging = false;

  // Выбранные для логирования метки (по deviceId). Пусто = логировать все.
  final Set<String> _logTargets = {};

  // Watchdog: перезапуск скана при остановке/застое (см. #6 — зависание).
  Timer? _watchdog;
  DateTime _lastResult = DateTime.now();

  @override
  void dispose() {
    _resultsSub?.cancel();
    _watchdog?.cancel();
    FlutterBluePlus.stopScan();
    ScannerLogger.instance.flushClose();
    super.dispose();
  }

  Future<bool> _ensurePermissions() async {
    final results = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    return results[Permission.bluetoothScan]?.isGranted == true &&
        results[Permission.bluetoothConnect]?.isGranted == true;
  }

  Future<void> _toggle() async {
    if (_scanning) {
      _scanning = false;
      _watchdog?.cancel();
      _watchdog = null;
      await FlutterBluePlus.stopScan();
      await _resultsSub?.cancel();
      _resultsSub = null;
      if (mounted) setState(() {});
      return;
    }

    if (!await _ensurePermissions()) {
      _showSnack('Нужны разрешения Bluetooth');
      return;
    }

    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (_) {
        _showSnack('Включите Bluetooth');
        return;
      }
    }

    if (!mounted) return;
    setState(() {
      _beacons.clear();
      _scanning = true;
    });

    _lastResult = DateTime.now();
    _resultsSub = FlutterBluePlus.scanResults.listen((results) {
      if (!mounted) return;
      _lastResult = DateTime.now();
      for (final r in results) {
        final parsed = parseAdvertisement(r);
        _beacons[parsed.deviceId] = parsed;
        // Логируем, если запись включена и метка выбрана (или выбор пуст = все).
        if (_logging &&
            (_logTargets.isEmpty || _logTargets.contains(parsed.deviceId))) {
          unawaited(ScannerLogger.instance.record(
            id: parsed.deviceId,
            name: parsed.name ?? parsed.kind.label,
            rssi: parsed.rssi,
          ));
        }
      }
      if (results.isNotEmpty) setState(() {});
    });

    await _startScan();

    // Watchdog: каждые 3 с чистим устаревшие метки и перезапускаем скан,
    // если система его молча остановила или он «завис» (нет обновлений).
    _watchdog = Timer.periodic(
        const Duration(seconds: 3), (_) => _watchdogTick());
  }

  Future<void> _startScan() async {
    try {
      await FlutterBluePlus.startScan(
        continuousUpdates: true,
        removeIfGone: const Duration(seconds: 10),
      );
    } catch (e) {
      _showSnack('Ошибка скана: $e');
    }
  }

  Future<void> _watchdogTick() async {
    if (!_scanning) return;
    final now = DateTime.now();

    // Чистим метки, не виденные дольше 20 с (страховка к removeIfGone).
    final stale = _beacons.entries
        .where((e) => now.difference(e.value.seenAt).inSeconds > 20)
        .map((e) => e.key)
        .toList();
    if (stale.isNotEmpty) {
      for (final k in stale) {
        _beacons.remove(k);
      }
      if (mounted) setState(() {});
    }

    // Перезапуск, если скан реально не идёт или нет обновлений > 10 с.
    final stalled = now.difference(_lastResult).inSeconds > 10;
    if (!FlutterBluePlus.isScanningNow || stalled) {
      try {
        await FlutterBluePlus.stopScan();
        await _startScan();
        _lastResult = DateTime.now();
      } catch (_) {}
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Экспорт CSV-лога сканера (поделиться файлом).
  Future<void> _exportLog() async {
    try {
      final size = await ScannerLogger.instance.sizeBytes();
      if (size <= 40) {
        _showSnack('Лог пуст — включите запись (кнопка ●)');
        return;
      }
      final path = await ScannerLogger.instance.fileForExport();
      await Share.shareXFiles([XFile(path)], subject: 'Лог сканера BLE');
    } catch (e) {
      _showSnack('Экспорт: $e');
    }
  }

  Future<void> _clearLog() async {
    await ScannerLogger.instance.clear();
    _showSnack('Лог сканера очищен');
  }

  /// Добавить/убрать метку из набора логируемых.
  void _toggleLogTarget(ParsedBeacon b) {
    setState(() {
      if (_logTargets.contains(b.deviceId)) {
        _logTargets.remove(b.deviceId);
      } else {
        _logTargets.add(b.deviceId);
      }
    });
  }

  Color _kindColor(BeaconKind k) => switch (k) {
        BeaconKind.iBeacon => AppColors.primaryLight,
        BeaconKind.eddystoneUid => AppColors.success,
        BeaconKind.eddystoneUrl => const Color(0xFFFFB74D),
        BeaconKind.eddystoneTlm => const Color(0xFFBA68C8),
        BeaconKind.stown => AppColors.primary,
        BeaconKind.custom => const Color(0xFF4DD0E1),
        BeaconKind.generic => AppColors.onSurfaceMuted,
      };

  Color _rssiColor(int rssi) {
    if (rssi >= -60) return AppColors.success;
    if (rssi >= -80) return const Color(0xFFFFB74D);
    return AppColors.danger;
  }

  IconData _rssiIcon(int rssi) {
    if (rssi >= -60) return Icons.wifi;
    if (rssi >= -80) return Icons.network_wifi_3_bar;
    return Icons.network_wifi_1_bar;
  }

  @override
  Widget build(BuildContext context) {
    final items = _beacons.values
        .where((b) => _filter == null || b.kind == _filter)
        .toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        actions: [
          IconButton(
            icon: Icon(
              _logging ? Icons.fiber_manual_record : Icons.fiber_manual_record_outlined,
              color: _logging ? AppColors.danger : AppColors.onSurfaceMuted,
            ),
            tooltip: _logging ? 'Запись вкл.' : 'Запись выкл.',
            onPressed: () {
              setState(() => _logging = !_logging);
              if (_logging) {
                _showSnack(_logTargets.isEmpty
                    ? 'Запись всех меток'
                    : 'Запись выбранных меток: ${_logTargets.length}');
              }
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: AppColors.primary),
            tooltip: 'Лог сканера',
            onSelected: (v) {
              if (v == 'export') _exportLog();
              if (v == 'clear') _clearLog();
              if (v == 'unselect') {
                setState(_logTargets.clear);
                _showSnack('Выбор меток сброшен');
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                  value: 'export', child: Text('Экспорт лога (CSV)')),
              const PopupMenuItem(value: 'clear', child: Text('Очистить лог')),
              if (_logTargets.isNotEmpty)
                const PopupMenuItem(
                    value: 'unselect', child: Text('Сбросить выбор меток')),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: AppColors.primary),
            tooltip: 'Выйти',
            onPressed: () => performLogout(
              context,
              onBeforeLogout: () async {
                _watchdog?.cancel();
                await FlutterBluePlus.stopScan();
                await _resultsSub?.cancel();
                await ScannerLogger.instance.flushClose();
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
                color: _scanning ? AppColors.success : AppColors.danger,
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Сканер'),
                Text(
                  _logging
                      ? (_logTargets.isEmpty
                          ? '● Запись всех · найдено ${_beacons.length}'
                          : '● Запись ${_logTargets.length} меток')
                      : (_scanning
                          ? 'Поиск... найдено ${_beacons.length}'
                          : 'Остановлен'),
                  style: TextStyle(
                    color: _logging
                        ? AppColors.danger
                        : AppColors.onSurfaceMuted,
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _filterChip('Все', null),
                  _filterChip('iBeacon', BeaconKind.iBeacon),
                  _filterChip('Eddy UID', BeaconKind.eddystoneUid),
                  _filterChip('Eddy URL', BeaconKind.eddystoneUrl),
                  _filterChip('Метка', BeaconKind.stown),
                  _filterChip('Custom', BeaconKind.custom),
                  _filterChip('Generic', BeaconKind.generic),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SizedBox(
              width: double.infinity,
              child: PrimaryGradientButton(
                label: _scanning ? 'Остановить поиск' : 'Начать поиск',
                icon: _scanning ? Icons.stop : Icons.bluetooth_searching,
                onPressed: _toggle,
                color: _scanning ? AppColors.danger : null,
              ),
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _scanning
                              ? Icons.radar
                              : Icons.bluetooth_disabled,
                          size: 64,
                          color: AppColors.onSurfaceMuted,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _scanning
                              ? 'Ожидание устройств...'
                              : 'Нажмите «Начать поиск»',
                          style: const TextStyle(
                            color: AppColors.onSurfaceMuted,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _tile(items[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String label, BeaconKind? kind) {
    final selected = _filter == kind;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => setState(() => _filter = kind),
        backgroundColor: AppColors.surface,
        selectedColor: AppColors.primary.withValues(alpha: 0.25),
        labelStyle: TextStyle(
          color: selected ? AppColors.primary : AppColors.onSurface,
          fontWeight: FontWeight.w600,
        ),
        side: BorderSide(
          color: selected ? AppColors.primary : AppColors.divider,
        ),
      ),
    );
  }

  Widget _tile(ParsedBeacon b) {
    final color = _kindColor(b.kind);
    return StownCard(
      onTap: () => _showDetails(b),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.bluetooth, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    KindBadge(label: b.kind.label, color: color),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        b.name ?? 'Неизвестное устройство',
                        style: const TextStyle(
                          color: AppColors.onSurface,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  b.deviceId,
                  style: const TextStyle(
                    color: AppColors.onSurfaceMuted,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
                if (b.fields.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    b.fields.entries.take(1).map((e) => '${e.key}: ${e.value}').join(' · '),
                    style: const TextStyle(
                      color: AppColors.onSurfaceMuted,
                      fontSize: 12,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 4),
          // Выбор метки для логирования.
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(
              _logTargets.contains(b.deviceId)
                  ? Icons.playlist_add_check_circle
                  : Icons.playlist_add_circle_outlined,
              color: _logTargets.contains(b.deviceId)
                  ? AppColors.primary
                  : AppColors.onSurfaceMuted,
            ),
            tooltip: _logTargets.contains(b.deviceId)
                ? 'Логируется'
                : 'Логировать эту метку',
            onPressed: () => _toggleLogTarget(b),
          ),
          Column(
            children: [
              Icon(_rssiIcon(b.rssi), color: _rssiColor(b.rssi), size: 22),
              const SizedBox(height: 2),
              Text(
                '${b.rssi}',
                style: TextStyle(
                  color: _rssiColor(b.rssi),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showDetails(ParsedBeacon b) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppColors.divider,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  KindBadge(label: b.kind.label, color: _kindColor(b.kind)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      b.name ?? 'Неизвестное устройство',
                      style: const TextStyle(
                        color: AppColors.onSurface,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SelectableText(
                b.deviceId,
                style: const TextStyle(
                  color: AppColors.onSurfaceMuted,
                  fontFamily: 'monospace',
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(_rssiIcon(b.rssi), color: _rssiColor(b.rssi), size: 18),
                  const SizedBox(width: 6),
                  Text(
                    '${b.rssi} dBm',
                    style: TextStyle(
                      color: _rssiColor(b.rssi),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '≈ ${ScannerLogger.distanceFromRssi(b.rssi).toStringAsFixed(1)} м',
                    style: const TextStyle(
                      color: AppColors.onSurfaceMuted,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const ThinDivider(),
              const SizedBox(height: 12),
              ...b.fields.entries.map(
                (e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        e.key.toUpperCase(),
                        style: const TextStyle(
                          color: AppColors.onSurfaceMuted,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.0,
                        ),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        e.value,
                        style: const TextStyle(
                          color: AppColors.onSurface,
                          fontFamily: 'monospace',
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _logTargets.contains(b.deviceId),
                onChanged: (_) {
                  _toggleLogTarget(b);
                  setSheet(() {});
                },
                title: const Text('Логировать эту метку',
                    style: TextStyle(color: AppColors.onSurface, fontSize: 14)),
                subtitle: const Text(
                  'Запись только выбранных меток. Включите запись кнопкой ● в шапке.',
                  style:
                      TextStyle(color: AppColors.onSurfaceMuted, fontSize: 11),
                ),
                activeThumbColor: AppColors.primary,
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(context).maybePop();
                  _addToWhitelist(b);
                },
                icon: const Icon(Icons.playlist_add_check),
                label: const Text('В авторизованные ТС'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  /// Добавляет метку в белый список шлюза. Ключ: для STOWN — "STOWN:ИМЯ",
  /// иначе — MAC-адрес. Просит комментарий.
  Future<void> _addToWhitelist(ParsedBeacon b) async {
    final isStown = b.kind == BeaconKind.stown;
    final key = isStown ? 'STOWN:${b.name ?? ''}' : b.deviceId;
    final commentCtrl = TextEditingController(text: b.name ?? b.kind.label);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        title: const Text('В авторизованные ТС',
            style: TextStyle(color: AppColors.onSurface)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Ключ: $key',
              style: const TextStyle(
                color: AppColors.onSurfaceMuted,
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: commentCtrl,
              autofocus: true,
              style: const TextStyle(color: AppColors.onSurface),
              decoration: const InputDecoration(
                labelText: 'Комментарий / имя',
                prefixIcon: Icon(Icons.edit_note),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final cfg = await GatewayStorage.instance.load();
    final exists = cfg.whitelist
        .any((v) => (v.matchKey ?? '').toUpperCase() == key.toUpperCase());
    if (exists) {
      _showSnack('Уже в базе: $key');
      return;
    }
    final comment =
        commentCtrl.text.trim().isEmpty ? key : commentCtrl.text.trim();

    // Сохраняем реальные идентификаторы из рекламы, чтобы шлюз матчил сразу:
    //   метка → ID (stownId); iBeacon → UUID/Major/Minor; иначе → MAC.
    final vehicle = AuthorizedVehicle(
      name: comment,
      matchKey: key,
      stownId: isStown ? normalizeId(b.fields['ID']) : null,
      uuid: b.kind == BeaconKind.iBeacon ? b.fields['UUID'] : null,
      major: b.kind == BeaconKind.iBeacon
          ? int.tryParse(b.fields['Major'] ?? '')
          : null,
      minor: b.kind == BeaconKind.iBeacon
          ? int.tryParse(b.fields['Minor'] ?? '')
          : null,
      macAddress:
          (isStown || b.kind == BeaconKind.iBeacon) ? null : b.deviceId,
    );
    final updated = cfg.copyWith(
      whitelist: [...cfg.whitelist, vehicle],
    );
    await GatewayStorage.instance.save(updated);
    _showSnack('Добавлено в авторизованные: $comment');
  }
}
