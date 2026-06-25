import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/l10n/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../models/app_settings.dart';
import '../../models/ble_device.dart';
import '../../providers/ble_providers.dart';
import '../../providers/ui_providers.dart';
import '../format.dart';
import '../widgets/bluetooth_off_banner.dart';

/// S5 — BLE Device Manager (§11.7). Card thiết bị hiện tại (Gửi thử / Ngắt /
/// Quên), scan list "Thiết bị gần đây", toggle auto-reconnect + rung khi mất
/// BLE, debug console ẩn (chạm 5× vào FW version). Banner vàng khi Bluetooth tắt.
class BleDeviceManagerScreen extends ConsumerStatefulWidget {
  const BleDeviceManagerScreen({super.key});

  @override
  ConsumerState<BleDeviceManagerScreen> createState() =>
      _BleDeviceManagerScreenState();
}

class _BleDeviceManagerScreenState
    extends ConsumerState<BleDeviceManagerScreen> {
  int _fwTaps = 0;
  bool _debugVisible = false;
  final List<String> _log = [];

  @override
  void initState() {
    super.initState();
    // Lắng nghe nút HUD để hiện trong debug console.
    final bridge = ref.read(bleBridgeProvider);
    bridge.buttonEvents.listen((e) {
      if (mounted) {
        setState(() {
          _log.insert(0, 'RX BTN ${e.name} (0x${e.value.toRadixString(16)})');
          if (_log.length > 50) _log.removeLast();
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(bleStatusValueProvider);
    final scan = ref.watch(bleScanProvider);
    final pairedDevice = ref.watch(pairedBleDeviceProvider);
    final settings = ref.watch(settingsProvider);
    final connected = status.state == BleConnectionState.connected;
    final showBleDiscovery = !connected;
    final hasKnownDevice = status.device != null || pairedDevice != null;

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.hudDeviceSection)),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const BluetoothOffBanner(marginBottom: 12),
          if (status.state == BleConnectionState.connected || hasKnownDevice)
            _currentDeviceCard(status, pairedDevice),
          if (!connected && !hasKnownDevice) _unpairedCard(),
          if (showBleDiscovery) ...[
            const SizedBox(height: 16),
            _scanHeader(scan),
            const SizedBox(height: 8),
            _scanList(scan),
          ],
          const SizedBox(height: 16),
          _toggles(settings),
          if (_debugVisible) ...[const SizedBox(height: 16), _debugConsole()],
        ],
      ),
    );
  }

  Widget _unpairedCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.bluetooth_disabled, color: context.scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                context.l10n.noHudConnected,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _currentDeviceCard(BleStatus status, DiscoveredDevice? pairedDevice) {
    final info = status.info;
    final systemInfo = status.systemInfo;
    final deviceStatus = status.deviceStatus;
    final connected = status.state == BleConnectionState.connected;
    final connecting = status.state == BleConnectionState.connecting;
    final disconnected = status.state == BleConnectionState.disconnected;
    final device = status.device ?? pairedDevice;
    final bridge = ref.read(bleBridgeProvider);
    final l10n = context.l10n;
    final stateLabel = connected
        ? l10n.connectedStatus
        : connecting
        ? l10n.connectingStatus
        : disconnected
        ? l10n.disconnectedStatus
        : l10n.pairedStatus;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 12,
                  color: connected
                      ? context.semantic.bleConnected
                      : context.semantic.danger,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    device?.name ?? 'NAVHUD',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(
                  stateLabel,
                  style: TextStyle(
                    color: connected
                        ? context.semantic.bleConnected
                        : context.semantic.danger,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // FW version — chạm 5× để mở debug console.
            GestureDetector(
              onTap: _onFwTap,
              child: Text(
                info == null
                    ? 'FW —'
                    : l10n.fwInfo(
                        info.fwVersionString,
                        info.maxText,
                        info.supportsDiacritics,
                      ),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'RSSI ${UiFormat.rssi(status.rssi)}  ·  MTU ${status.mtu ?? "—"}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: context.scheme.onSurfaceVariant,
              ),
            ),
            if (systemInfo != null) ...[
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 12),
              Text(
                '${systemInfo.mcuDescription} · ${systemInfo.screenType.label} '
                '${systemInfo.screenWidth}×${systemInfo.screenHeight}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                'Vendor ${systemInfo.vendorIdString} · '
                'Model ${systemInfo.modelIdString} · '
                'Product ${systemInfo.productIdString}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                'HW ${systemInfo.hardwareVersionString} · '
                'SN ${systemInfo.serialNumber} · '
                '${systemInfo.manufacturerDate}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (deviceStatus != null) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _statusChip(
                    Icons.memory,
                    'Heap ${(deviceStatus.freeHeapBytes / 1024).round()} KB',
                  ),
                  _statusChip(
                    Icons.timer_outlined,
                    'Uptime ${_formatUptime(deviceStatus.uptime)}',
                  ),
                  if (deviceStatus.batteryPresent)
                    _statusChip(
                      deviceStatus.charging
                          ? Icons.battery_charging_full
                          : Icons.battery_std,
                      deviceStatus.batteryPercent == null
                          ? 'Battery —'
                          : 'Battery ${deviceStatus.batteryPercent}%',
                    ),
                  _statusChip(
                    deviceStatus.screenOn
                        ? Icons.screen_lock_portrait
                        : Icons.screen_lock_portrait_outlined,
                    deviceStatus.screenOn ? 'Screen on' : 'Screen off',
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!connected)
                  FilledButton.icon(
                    onPressed: connecting || device == null
                        ? null
                        : () {
                            ref
                                .read(pairedBleDeviceProvider.notifier)
                                .set(device);
                            unawaited(bridge.connectTo(device));
                          },
                    icon: const Icon(Icons.bluetooth_connected),
                    label: Text(l10n.connect),
                  ),
                OutlinedButton.icon(
                  onPressed: connected ? bridge.sendTestInstruction : null,
                  icon: const Icon(Icons.send),
                  label: Text(l10n.sendTest),
                ),
                OutlinedButton.icon(
                  onPressed: status.state == BleConnectionState.unpaired
                      ? null
                      : () => bridge.disconnect(),
                  icon: const Icon(Icons.link_off),
                  label: Text(l10n.disconnect),
                ),
                OutlinedButton.icon(
                  onPressed: () {
                    ref.read(pairedBleDeviceProvider.notifier).clear();
                    bridge.forget();
                  },
                  icon: const Icon(Icons.delete_outline),
                  label: Text(l10n.forget),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(IconData icon, String label) {
    return Chip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(icon, size: 16),
      label: Text(label),
    );
  }

  String _formatUptime(Duration uptime) {
    final hours = uptime.inHours;
    final minutes = uptime.inMinutes.remainder(60);
    return hours > 0 ? '${hours}h ${minutes}m' : '${minutes}m';
  }

  Widget _scanHeader(BleScanState scan) {
    return Row(
      children: [
        Expanded(
          child: Text(
            context.l10n.nearbyNusDevices,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        FilledButton.icon(
          onPressed: () {
            final controller = ref.read(bleScanProvider.notifier);
            if (scan.isScanning) {
              unawaited(controller.stop());
            } else {
              unawaited(_startScan());
            }
          },
          icon: Icon(scan.isScanning ? Icons.stop : Icons.bluetooth_searching),
          label: Text(scan.isScanning ? context.l10n.stop : context.l10n.scan),
        ),
      ],
    );
  }

  Widget _scanList(BleScanState scan) {
    final error = scan.error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(context.l10n.scanError(error)),
      );
    }

    if (!scan.hasScanned) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(context.l10n.scanPrompt, textAlign: TextAlign.center),
      );
    }

    if (scan.devices.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          children: [
            if (scan.isScanning) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 12),
              Text(context.l10n.scanningNus, textAlign: TextAlign.center),
            ] else ...[
              const Icon(Icons.bluetooth_searching, size: 40),
              const SizedBox(height: 8),
              Text(context.l10n.noHudFound, textAlign: TextAlign.center),
            ],
          ],
        ),
      );
    }

    final bridge = ref.read(bleBridgeProvider);
    return Column(
      children: [
        if (scan.isScanning) const LinearProgressIndicator(minHeight: 2),
        for (final d in scan.devices)
          ListTile(
            leading: const Icon(Icons.bluetooth),
            title: Text(d.name),
            subtitle: Text(d.id),
            trailing: Text('${d.rssi} dBm'),
            onTap: () {
              ref.read(pairedBleDeviceProvider.notifier).set(d);
              unawaited(ref.read(bleScanProvider.notifier).stop());
              unawaited(bridge.connectTo(d));
            },
          ),
      ],
    );
  }

  Widget _toggles(AppSettings settings) {
    return Column(
      children: [
        SwitchListTile(
          title: Text(context.l10n.autoReconnectTitle),
          value: settings.autoReconnectBle,
          onChanged: (v) => ref
              .read(settingsProvider.notifier)
              .update(settings.copyWith(autoReconnectBle: v)),
        ),
        SwitchListTile(
          title: Text(context.l10n.vibrateBleLostTitle),
          value: settings.vibrateOnBleLost,
          onChanged: (v) => ref
              .read(settingsProvider.notifier)
              .update(settings.copyWith(vibrateOnBleLost: v)),
        ),
      ],
    );
  }

  Widget _debugConsole() {
    return Card(
      color: Colors.black,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Debug console (hex frame TX/RX)',
              style: TextStyle(color: Colors.greenAccent),
            ),
            const SizedBox(height: 8),
            if (_log.isEmpty)
              const Text(
                '— chưa có sự kiện —',
                style: TextStyle(color: Colors.white54),
              ),
            for (final line in _log)
              Text(
                line,
                style: const TextStyle(
                  color: Colors.greenAccent,
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _onFwTap() {
    _fwTaps++;
    if (_fwTaps >= 5 && !_debugVisible) {
      setState(() => _debugVisible = true);
    }
  }

  Future<void> _startScan() async {
    final controller = ref.read(bleScanProvider.notifier);
    final permissionError = await _blePermissionError();
    if (permissionError != null) {
      controller.fail(permissionError);
      return;
    }
    await controller.start();
  }

  Future<String?> _blePermissionError() async {
    final l10n = context.l10n;
    try {
      if (!Platform.isAndroid && !Platform.isIOS) return null;

      if (Platform.isIOS) {
        final status = await Permission.bluetooth.request();
        return status.isGranted || status.isLimited
            ? null
            : l10n.blePermissionRequired;
      }

      final bluetooth = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();
      final location = await Permission.locationWhenInUse.request();

      final scanStatus = bluetooth[Permission.bluetoothScan];
      final connectStatus = bluetooth[Permission.bluetoothConnect];
      final nearbyGranted =
          (scanStatus?.isGranted ?? false) &&
          (connectStatus?.isGranted ?? false);
      final legacyLocationGranted = location.isGranted || location.isLimited;

      if (nearbyGranted || legacyLocationGranted) return null;
      if ((scanStatus?.isPermanentlyDenied ?? false) ||
          (connectStatus?.isPermanentlyDenied ?? false) ||
          location.isPermanentlyDenied) {
        return l10n.blePermissionBlocked;
      }
    } catch (e) {
      return l10n.blePermissionCheckError(e);
    }
    return l10n.blePermissionRequired;
  }
}
