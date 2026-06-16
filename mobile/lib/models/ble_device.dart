/// Display configuration for a specific HUD model (screen + mini-map area).
class HudDisplayConfig {
  final int screenW;
  final int screenH;
  final int mapW;
  final int mapH;

  const HudDisplayConfig({
    required this.screenW,
    required this.screenH,
    required this.mapW,
    required this.mapH,
  });
}

const _hudDisplayConfigs = <int, HudDisplayConfig>{
  0x0001: HudDisplayConfig(screenW: 240, screenH: 320, mapW: 240, mapH: 180),
  0x0002: HudDisplayConfig(screenW: 320, screenH: 240, mapW: 200, mapH: 160),
};

const _defaultHudConfig = HudDisplayConfig(
  screenW: 240,
  screenH: 320,
  mapW: 240,
  mapH: 180,
);

/// Look up display config by model ID; falls back to default 240×320/240×180.
HudDisplayConfig hudConfigForModel(int modelId) =>
    _hudDisplayConfigs[modelId] ?? _defaultHudConfig;

/// Thiết bị HUD quét được (scan list S5).
class DiscoveredDevice {
  final String id; // remoteId / MAC / UUID tuỳ nền
  final String name;
  final int rssi;

  const DiscoveredDevice({
    required this.id,
    required this.name,
    required this.rssi,
  });

  factory DiscoveredDevice.fromJson(Map<String, dynamic> json) {
    return DiscoveredDevice(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'NAVHUD',
      rssi: (json['rssi'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'rssi': rssi};
}

/// Trạng thái kết nối BLE (4 trạng thái chip §11.3).
enum BleConnectionState {
  /// Xám — chưa ghép thiết bị nào.
  unpaired,

  /// Vàng nhấp nháy — đang scan/connect/handshake.
  connecting,

  /// Xanh — đã kết nối + handshake xong.
  connected,

  /// Đỏ — mất kết nối (đang auto-reconnect backoff).
  disconnected,
}

/// Thông tin thiết bị trả về từ DEVICE_INFO (CMD 0x04).
class DeviceInfo {
  static const int defaultMaxText = 48;

  final int hardwareVersion;
  final int firmwareVersion;
  final int capBitmap; // legacy u16 — bit cờ năng lực
  final int maxText; // số byte text tối đa app nên gửi trên từng field

  final String manufacturerId;
  final String serialNumber;
  final int productId;
  final int modelId;

  const DeviceInfo({
    this.hardwareVersion = 0,
    this.firmwareVersion = 0,
    this.capBitmap = capDiacritics,
    this.maxText = defaultMaxText,
    this.manufacturerId = '',
    this.serialNumber = '',
    this.productId = 0,
    this.modelId = 0,
  });

  /// Capability bits (khớp firmware).
  static const int capDiacritics = 1 << 0; // hỗ trợ hiển thị dấu tiếng Việt
  static const int capSpeedLimit = 1 << 1;
  static const int capTrafficSign = 1 << 2;
  static const int capLaneInfo = 1 << 3;
  static const int capButtons = 1 << 4;

  bool get supportsDiacritics => capBitmap & capDiacritics != 0;
  bool get supportsSpeedLimit => capBitmap & capSpeedLimit != 0;
  bool get supportsTrafficSign => capBitmap & capTrafficSign != 0;

  String get fwVersionString {
    if (firmwareVersion > 0xFFFF) return _hex32(firmwareVersion);
    final major = (firmwareVersion >> 8) & 0xFF;
    final minor = (firmwareVersion >> 4) & 0x0F;
    final patch = firmwareVersion & 0x0F;
    return '$major.$minor.$patch';
  }

  String get hardwareVersionString => _hex32(hardwareVersion);
  String get productIdString => _hex32(productId);
  String get modelIdString => _hex32(modelId);

  static String _hex32(int value) =>
      '0x${(value & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0').toUpperCase()}';
}

/// Snapshot trạng thái BLE cho UI (chip + S5 card).
class BleStatus {
  final BleConnectionState state;
  final DiscoveredDevice? device;
  final DeviceInfo? info;
  final int? rssi;
  final int? mtu;

  /// Giây còn lại tới lần reconnect kế (khi disconnected) — chip đếm ngược.
  final int reconnectInSeconds;

  const BleStatus({
    this.state = BleConnectionState.unpaired,
    this.device,
    this.info,
    this.rssi,
    this.mtu,
    this.reconnectInSeconds = 0,
  });

  BleStatus copyWith({
    BleConnectionState? state,
    DiscoveredDevice? device,
    DeviceInfo? info,
    int? rssi,
    int? mtu,
    int? reconnectInSeconds,
  }) {
    return BleStatus(
      state: state ?? this.state,
      device: device ?? this.device,
      info: info ?? this.info,
      rssi: rssi ?? this.rssi,
      mtu: mtu ?? this.mtu,
      reconnectInSeconds: reconnectInSeconds ?? this.reconnectInSeconds,
    );
  }
}
