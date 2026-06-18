import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ble/ble_bridge.dart';
import '../models/ble_device.dart';
import 'app_providers.dart';
import 'ui_providers.dart';

class BleScanState {
  final List<DiscoveredDevice> devices;
  final bool isScanning;
  final bool hasScanned;
  final Object? error;

  const BleScanState({
    this.devices = const [],
    this.isScanning = false,
    this.hasScanned = false,
    this.error,
  });
}

class PairedBleDeviceNotifier extends Notifier<DiscoveredDevice?> {
  static const _key = 'paired_ble_device';

  @override
  DiscoveredDevice? build() {
    final raw = ref.read(sharedPrefsProvider).getString(_key);
    if (raw == null) return null;
    try {
      return DiscoveredDevice.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  void set(DiscoveredDevice device) {
    state = device;
    ref.read(sharedPrefsProvider).setString(_key, jsonEncode(device.toJson()));
  }

  void clear() {
    state = null;
    ref.read(sharedPrefsProvider).remove(_key);
  }
}

final pairedBleDeviceProvider =
    NotifierProvider<PairedBleDeviceNotifier, DiscoveredDevice?>(
      PairedBleDeviceNotifier.new,
    );

class BleScanController extends Notifier<BleScanState> {
  StreamSubscription<List<DiscoveredDevice>>? _sub;
  Timer? _timeout;

  @override
  BleScanState build() {
    final transport = ref.read(bleTransportProvider);
    ref.onDispose(() {
      _timeout?.cancel();
      _sub?.cancel();
      transport.stopScan();
    });
    return const BleScanState();
  }

  Future<void> start({Duration timeout = const Duration(seconds: 15)}) async {
    await _cancelScan();
    state = const BleScanState(isScanning: true, hasScanned: true);
    try {
      final transport = ref.read(bleTransportProvider);
      await transport.stopScan();
      _sub = transport
          .scan(timeout: timeout)
          .listen(
            (devices) {
              state = BleScanState(
                devices: devices,
                isScanning: true,
                hasScanned: true,
              );
            },
            onError: (Object e) {
              state = BleScanState(hasScanned: true, error: e);
            },
          );
      _timeout = Timer(timeout, () {
        unawaited(stop());
      });
    } catch (e) {
      state = BleScanState(hasScanned: true, error: e);
    }
  }

  Future<void> stop() async {
    await _cancelScan();
    state = BleScanState(
      devices: state.devices,
      hasScanned: state.hasScanned,
      error: state.error,
    );
  }

  void fail(Object error) {
    state = BleScanState(
      devices: state.devices,
      hasScanned: true,
      error: error,
    );
  }

  Future<void> _cancelScan() async {
    _timeout?.cancel();
    _timeout = null;
    await _sub?.cancel();
    _sub = null;
    await ref.read(bleTransportProvider).stopScan();
  }
}

/// BLE Bridge — subscriber NavEvent, sống suốt vòng đời app.
/// Đồng bộ prefs (sendFull / stripDiacritics / autoReconnect) từ settings.
final bleBridgeProvider = Provider<BleBridge>((ref) {
  final bridge = BleBridge(
    ref.watch(bleTransportProvider),
    ref.watch(navEventBusProvider),
  );
  var autoConnectStarted = false;

  void maybeAutoConnect() {
    if (autoConnectStarted) return;
    final s = ref.read(settingsProvider);
    if (!s.autoReconnectBle) return;
    if (bridge.currentStatus.state != BleConnectionState.unpaired) return;
    final device = ref.read(pairedBleDeviceProvider);
    if (device == null) return;
    autoConnectStarted = true;
    unawaited(bridge.connectTo(device));
  }

  void applySettings() {
    final s = ref.read(settingsProvider);
    bridge.sendFullContent = s.sendFullContent;
    bridge.forceStripDiacritics = s.forceStripDiacritics;
    bridge.autoReconnect = s.autoReconnectBle;
    maybeAutoConnect();
  }

  applySettings();
  ref.listen(settingsProvider, (_, _) => applySettings());
  ref.onDispose(bridge.dispose);
  return bridge;
});

/// Trạng thái BLE cho chip (§11.3) + S5. Seed bằng currentStatus.
final bleStatusProvider = StreamProvider<BleStatus>((ref) {
  final bridge = ref.watch(bleBridgeProvider);
  return bridge.status;
});

/// Tiện ích đọc BleStatus dạng giá trị (không AsyncValue).
final bleStatusValueProvider = Provider<BleStatus>((ref) {
  final bridge = ref.watch(bleBridgeProvider);
  return ref.watch(bleStatusProvider).value ?? bridge.currentStatus;
});

/// Kết quả scan NUS (S5 scan list). Chỉ scan khi người dùng bấm nút Quét.
final bleScanProvider = NotifierProvider<BleScanController, BleScanState>(
  BleScanController.new,
);

/// Bluetooth adapter bật/tắt (§11.9).
final bleAdapterProvider = StreamProvider<bool>((ref) {
  return ref.watch(bleTransportProvider).adapterState;
});

/// Dữ liệu map cuối cùng đã gửi cho ESP32 — dùng cho HUD sim "BLE Live".
/// Phát mỗi khi MAP_POSE hoặc MAP_ROUTE/ROADS được encode và enqueue.
/// Seed bằng currentMapSnapshot để ESP preview không bị kẹt ở "Chờ BLE..."
/// khi snapshot đã có từ trước (vd: mở preview giữa chừng navigation).
final bleMapSnapshotProvider = StreamProvider<BleMapSnapshot>((ref) {
  final bridge = ref.watch(bleBridgeProvider);
  final initial = bridge.currentMapSnapshot;
  if (initial == null) return bridge.mapSnapshots;

  // Phát snapshot hiện tại ngay lập tức, sau đó tiếp tục nghe stream.
  final ctrl = StreamController<BleMapSnapshot>();
  ctrl.add(initial);
  final sub = bridge.mapSnapshots.listen(
    ctrl.add,
    onError: ctrl.addError,
    onDone: ctrl.close,
  );
  ref.onDispose(() {
    sub.cancel();
    ctrl.close();
  });
  return ctrl.stream;
});
