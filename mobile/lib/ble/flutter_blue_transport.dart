import 'dart:async';

import 'package:flutter/foundation.dart';
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
  DateTime? _lastGattReleaseAt;

  static const Duration _androidGattCooldown = Duration(seconds: 3);

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
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _rx = null;
    _tx = null;

    await stopScan();
    await _waitForAndroidGattCooldown();

    final device = BluetoothDevice.fromId(deviceId);
    _device = device;

    debugPrint('[BleTransport] connect: $deviceId — gọi device.connect()');
    await device.connect(
      license: License.nonprofit,
      timeout: const Duration(seconds: 15),
      autoConnect: false,
      mtu: null,
    );
    debugPrint('[BleTransport] connect: GATT connected, requestMtu…');

    // MTU 247 (Android). iOS bỏ qua (tự negotiate).
    try {
      _mtu = await device.requestMtu(Nus.desiredMtu);
    } catch (e) {
      _mtu = device.mtuNow;
      debugPrint('[BleTransport] requestMtu failed ($e), dùng mtuNow=$_mtu');
    }
    debugPrint('[BleTransport] MTU=$_mtu, discoverServices…');

    final services = await _discoverServicesWithGattCacheRecovery(device);
    final svc = services.firstWhere(
      (s) => s.uuid == Guid(Nus.serviceUuid),
      orElse: () => throw StateError(
        'Thiết bị không có NUS service; services=${_formatServices(services)}',
      ),
    );
    for (final c in svc.characteristics) {
      if (c.uuid == Guid(Nus.rxCharUuid)) _rx = c;
      if (c.uuid == Guid(Nus.txCharUuid)) _tx = c;
    }
    final tx = _tx;
    if (_rx == null || tx == null) {
      throw StateError('Thiếu RX/TX characteristic NUS');
    }

    debugPrint('[BleTransport] setNotifyValue…');
    try {
      await tx.setNotifyValue(true);
    } catch (e) {
      debugPrint('[BleTransport] setNotifyValue attempt 1 failed ($e), retry…');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tx.setNotifyValue(true);
    }
    _subs.add(
      tx.onValueReceived.listen((bytes) {
        _incoming.add(Uint8List.fromList(bytes));
      }),
    );

    _subs.add(
      device.connectionState.listen((s) {
        debugPrint('[BleTransport] connectionState: $s');
        if (s == BluetoothConnectionState.connected) {
          _connState.add(BleConnectionState.connected);
        } else if (s == BluetoothConnectionState.disconnected) {
          _connState.add(BleConnectionState.disconnected);
        }
      }),
    );
    debugPrint('[BleTransport] connect: hoàn tất — MTU=$_mtu');
  }

  @override
  Future<void> disconnect() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _device?.disconnect(queue: false);
    _lastGattReleaseAt = DateTime.now();
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

  Future<void> _waitForAndroidGattCooldown() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    final releasedAt = _lastGattReleaseAt;
    if (releasedAt == null) return;

    final elapsed = DateTime.now().difference(releasedAt);
    if (elapsed >= _androidGattCooldown) return;

    final remaining = _androidGattCooldown - elapsed;
    debugPrint(
      '[BleTransport] Android GATT cooldown '
      '${remaining.inMilliseconds}ms before connect',
    );
    await Future<void>.delayed(remaining);
  }

  Future<List<BluetoothService>> _discoverServicesWithGattCacheRecovery(
    BluetoothDevice device,
  ) async {
    var services = await device.discoverServices();
    _logDiscoveredServices(services, attempt: 1);

    if (_hasNusService(services) ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      return services;
    }

    debugPrint(
      '[BleTransport] NUS service missing; clearing Android GATT cache',
    );
    try {
      await device.clearGattCache();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      services = await device.discoverServices();
      _logDiscoveredServices(services, attempt: 2);
    } catch (e) {
      debugPrint('[BleTransport] clearGattCache/rediscover failed: $e');
    }
    return services;
  }

  bool _hasNusService(List<BluetoothService> services) =>
      services.any((s) => s.uuid == Guid(Nus.serviceUuid));

  void _logDiscoveredServices(
    List<BluetoothService> services, {
    required int attempt,
  }) {
    debugPrint(
      '[BleTransport] discoverServices#$attempt: '
      '${services.length} service(s): ${_formatServices(services)}',
    );
  }

  String _formatServices(List<BluetoothService> services) {
    if (services.isEmpty) return '<none>';
    return services
        .map((s) {
          final chars = s.characteristics
              .map((c) => c.uuid.toString())
              .join(',');
          return '${s.uuid}[$chars]';
        })
        .join(' | ');
  }
}
