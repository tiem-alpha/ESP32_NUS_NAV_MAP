import 'dart:typed_data';

import '../models/ble_device.dart';

/// Abstraction transport BLE — Strategy/DI để swap plugin
/// (`flutter_blue_plus` ↔ `bluetooth_low_energy`) mà không đụng codec/bridge
/// (§3.2). Bridge chỉ phụ thuộc interface này.
abstract interface class IBleTransport {
  /// Bluetooth adapter có đang bật không.
  Stream<bool> get adapterState;

  /// Bật nhanh Bluetooth adapter (chỉ Android — §11.9 banner "Bluetooth tắt").
  Future<void> turnOnAdapter();

  /// Bắt đầu scan NUS (filter theo service UUID + prefix tên).
  Stream<List<DiscoveredDevice>> scan({Duration? timeout});
  Future<void> stopScan();

  /// Kết nối + request MTU + discover + enable notify TX char.
  Future<void> connect(String deviceId);
  Future<void> disconnect();

  /// Ghi vào RX char. [withResponse]=true cho gói quan trọng (§5.3).
  Future<void> write(Uint8List data, {bool withResponse = false});

  /// Bytes nhận từ TX char (notify) — đẩy vào NusParser.
  Stream<Uint8List> get incoming;

  /// Trạng thái kết nối ở mức transport.
  Stream<BleConnectionState> get connectionState;

  /// MTU thực tế sau negotiate (để codec quyết định fragment).
  int get mtu;

  /// RSSI hiện tại của thiết bị đã kết nối (nếu đọc được).
  Future<int?> readRssi();

  /// Ưu tiên kết nối: HIGH khi navigate, BALANCED khi idle (§5.2).
  Future<void> setHighPriority(bool high);

  void dispose();
}
