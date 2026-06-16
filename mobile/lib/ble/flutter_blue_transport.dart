import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/ble_device.dart';
import 'i_ble_transport.dart';
import 'nus_constants.dart';

/// `IBleTransport` cài đặt bằng `flutter_blue_plus` (§3.2).
/// ⚠️ flutter_blue_plus cần commercial license cho mục đích thương mại —
/// nhờ interface này, có thể swap sang `bluetooth_low_energy` (BSD) mà không
/// đụng codec/bridge.
class FlutterBlueTransport implements IBleTransport {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _rx; // app GHI vào (NUS RX)
  BluetoothCharacteristic? _tx; // app NHẬN từ (NUS TX, notify)
  int _mtu = 23;

  final _incoming = StreamController<Uint8List>.broadcast();
  final _connState = StreamController<BleConnectionState>.broadcast();
  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  int get mtu => _mtu;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Stream<BleConnectionState> get connectionState => _connState.stream;

  @override
  Stream<bool> get adapterState =>
      FlutterBluePlus.adapterState.map((s) => s == BluetoothAdapterState.on);

  @override
  Future<void> turnOnAdapter() async {
    try {
      await FlutterBluePlus.turnOn();
    } catch (_) {
      // iOS hoặc người dùng từ chối dialog hệ thống — bỏ qua.
    }
  }

  @override
  Stream<List<DiscoveredDevice>> scan({Duration? timeout}) {
    FlutterBluePlus.startScan(
      withServices: [Guid(Nus.serviceUuid)],
      timeout: timeout ?? const Duration(seconds: 15),
      androidUsesFineLocation: false,
    );
    return FlutterBluePlus.scanResults.map((results) {
      // Một số HUD không quảng bá service UUID trong adv packet → giữ cả 2 nguồn.
      final seen = <String, DiscoveredDevice>{};
      for (final r in results) {
        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : r.device.platformName;
        if (name.isEmpty && !_advertisesNus(r)) continue;
        seen[r.device.remoteId.str] = DiscoveredDevice(
          id: r.device.remoteId.str,
          name: name.isEmpty ? 'Thiết bị BLE' : name,
          rssi: r.rssi,
        );
      }
      return seen.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
    });
  }

  bool _advertisesNus(ScanResult r) =>
      r.advertisementData.serviceUuids.any((g) => g == Guid(Nus.serviceUuid));

  @override
  Future<void> stopScan() => FlutterBluePlus.stopScan();

  @override
  Future<void> connect(String deviceId) async {
    await stopScan();
    final device = BluetoothDevice.fromId(deviceId);
    _device = device;

    // Theo dõi connection state ở mức transport.
    _subs.add(
      device.connectionState.listen((s) {
        _connState.add(
          s == BluetoothConnectionState.connected
              ? BleConnectionState.connected
              : BleConnectionState.disconnected,
        );
      }),
    );

    await device.connect(
      license: License.nonprofit,
      timeout: const Duration(seconds: 12),
      autoConnect: false,
    );

    // MTU 247 (Android). iOS bỏ qua (tự negotiate).
    try {
      _mtu = await device.requestMtu(Nus.desiredMtu);
    } catch (_) {
      _mtu = device.mtuNow;
    }

    final services = await device.discoverServices();
    final svc = services.firstWhere(
      (s) => s.uuid == Guid(Nus.serviceUuid),
      orElse: () => throw StateError('Thiết bị không có NUS service'),
    );
    for (final c in svc.characteristics) {
      if (c.uuid == Guid(Nus.rxCharUuid)) _rx = c;
      if (c.uuid == Guid(Nus.txCharUuid)) _tx = c;
    }
    final tx = _tx;
    if (_rx == null || tx == null) {
      throw StateError('Thiếu RX/TX characteristic NUS');
    }

    await tx.setNotifyValue(true);
    _subs.add(
      tx.onValueReceived.listen((bytes) {
        _incoming.add(Uint8List.fromList(bytes));
      }),
    );
  }

  @override
  Future<void> disconnect() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _device?.disconnect();
    _rx = null;
    _tx = null;
    _device = null;
  }

  @override
  Future<void> write(Uint8List data, {bool withResponse = false}) async {
    final rx = _rx;
    if (rx == null) return;
    await rx.write(data, withoutResponse: !withResponse, allowLongWrite: false);
  }

  @override
  Future<int?> readRssi() async {
    try {
      return await _device?.readRssi();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> setHighPriority(bool high) async {
    try {
      await _device?.requestConnectionPriority(
        connectionPriorityRequest: high
            ? ConnectionPriority.high
            : ConnectionPriority.balanced,
      );
    } catch (_) {
      // iOS không hỗ trợ — bỏ qua.
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _incoming.close();
    _connState.close();
  }
}
