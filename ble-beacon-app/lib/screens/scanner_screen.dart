import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/beacon.dart';
import '../services/beacon_parser.dart';
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
  StreamSubscription<bool>? _stateSub;
  bool _scanning = false;
  BeaconKind? _filter;

  @override
  void dispose() {
    _resultsSub?.cancel();
    _stateSub?.cancel();
    FlutterBluePlus.stopScan();
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
      await FlutterBluePlus.stopScan();
      await _resultsSub?.cancel();
      if (mounted) setState(() => _scanning = false);
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

    _resultsSub = FlutterBluePlus.scanResults.listen((results) {
      if (!mounted) return;
      var changed = false;
      for (final r in results) {
        final parsed = parseAdvertisement(r);
        _beacons[parsed.deviceId] = parsed;
        changed = true;
      }
      if (changed) setState(() {});
    });

    _stateSub = FlutterBluePlus.isScanning.listen((s) {
      if (mounted) setState(() => _scanning = s);
    });

    try {
      await FlutterBluePlus.startScan(
        continuousUpdates: true,
        removeIfGone: const Duration(seconds: 10),
      );
    } catch (e) {
      _showSnack('Ошибка скана: $e');
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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
            icon: const Icon(Icons.logout, color: AppColors.primary),
            tooltip: 'Выйти',
            onPressed: () => performLogout(
              context,
              onBeforeLogout: () async {
                await FlutterBluePlus.stopScan();
                await _resultsSub?.cancel();
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
                  _scanning
                      ? 'Поиск... найдено ${_beacons.length}'
                      : 'Остановлен',
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
                  _filterChip('STOWN', BeaconKind.stown),
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
          const SizedBox(width: 8),
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
      builder: (_) => SafeArea(
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
            ],
          ),
        ),
      ),
    );
  }
}
