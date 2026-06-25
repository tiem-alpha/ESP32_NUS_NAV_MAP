enum HudScreenType {
  none(0),
  mono(1),
  rgb565(2),
  rgb888(3);

  final int wire;
  const HudScreenType(this.wire);

  static HudScreenType fromWire(int value) => values.firstWhere(
    (type) => type.wire == value,
    orElse: () => HudScreenType.none,
  );

  String get label => switch (this) {
    HudScreenType.none => 'No display',
    HudScreenType.mono => 'Mono',
    HudScreenType.rgb565 => 'RGB565',
    HudScreenType.rgb888 => 'RGB888',
  };
}

/// Cấu hình màn hình lấy trực tiếp từ SYSTEM_INFO, không suy ra bằng model ID.
class HudDisplayConfig {
  final int screenW;
  final int screenH;
  final HudScreenType screenType;
  final bool supported;

  const HudDisplayConfig({
    required this.screenW,
    required this.screenH,
    required this.screenType,
    required this.supported,
  });

  static const fallback = HudDisplayConfig(
    screenW: 240,
    screenH: 320,
    screenType: HudScreenType.rgb565,
    supported: true,
  );

  factory HudDisplayConfig.fromSystemInfo(DeviceSystemInfo? info) {
    if (info == null) {
      return fallback;
    }
    if (!info.supportsScreen ||
        info.screenWidth <= 0 ||
        info.screenHeight <= 0) {
      return HudDisplayConfig(
        screenW: fallback.screenW,
        screenH: fallback.screenH,
        screenType: info.screenType,
        supported: false,
      );
    }
    return HudDisplayConfig(
      screenW: info.screenWidth,
      screenH: info.screenHeight,
      screenType: info.screenType,
      supported: info.supportsScreen,
    );
  }

  double get aspectRatio => screenW / screenH;
  double get userX => screenW * 0.5;
  double get userY => screenH * 0.75;
  bool get supportsGraphicalMap =>
      supported &&
      (screenType == HudScreenType.rgb565 ||
          screenType == HudScreenType.rgb888);
}

/// Thiết bị HUD quét được.
class DiscoveredDevice {
  final String id;
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

enum BleConnectionState { unpaired, connecting, connected, disconnected }

/// Handshake ngắn, tương thích DEVICE_INFO (0x02) hiện có.
class DeviceInfo {
  static const int defaultMaxText = 48;

  final int hardwareVersion;
  final int firmwareVersion;
  final int capBitmap;
  final int maxText;
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

  static const int capDiacritics = 1 << 0;
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

/// Thông tin sản phẩm tĩnh từ SYSTEM_INFO (0x03), cache theo BLE device ID.
class DeviceSystemInfo {
  static const int schemaVersion = 1;

  final int vendorId;
  final int modelId;
  final int productId;
  final int hardwareVersion;
  final String manufacturerDate;
  final String serialNumber;
  final bool supportsBattery;
  final bool supportsScreen;
  final HudScreenType screenType;
  final int screenWidth;
  final int screenHeight;
  final String mcuDescription;

  const DeviceSystemInfo({
    required this.vendorId,
    required this.modelId,
    required this.productId,
    required this.hardwareVersion,
    required this.manufacturerDate,
    required this.serialNumber,
    required this.supportsBattery,
    required this.supportsScreen,
    required this.screenType,
    required this.screenWidth,
    required this.screenHeight,
    required this.mcuDescription,
  });

  factory DeviceSystemInfo.fromJson(Map<String, dynamic> json) {
    if ((json['schema'] as num?)?.toInt() != schemaVersion) {
      throw const FormatException('Unsupported SYSTEM_INFO cache schema');
    }
    return DeviceSystemInfo(
      vendorId: (json['vendorId'] as num?)?.toInt() ?? 0,
      modelId: (json['modelId'] as num?)?.toInt() ?? 0,
      productId: (json['productId'] as num?)?.toInt() ?? 0,
      hardwareVersion: (json['hardwareVersion'] as num?)?.toInt() ?? 0,
      manufacturerDate: json['manufacturerDate'] as String? ?? '',
      serialNumber: json['serialNumber'] as String? ?? '',
      supportsBattery: json['supportsBattery'] as bool? ?? false,
      supportsScreen: json['supportsScreen'] as bool? ?? false,
      screenType: HudScreenType.fromWire(
        (json['screenType'] as num?)?.toInt() ?? 0,
      ),
      screenWidth: (json['screenWidth'] as num?)?.toInt() ?? 0,
      screenHeight: (json['screenHeight'] as num?)?.toInt() ?? 0,
      mcuDescription: json['mcuDescription'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'schema': schemaVersion,
    'vendorId': vendorId,
    'modelId': modelId,
    'productId': productId,
    'hardwareVersion': hardwareVersion,
    'manufacturerDate': manufacturerDate,
    'serialNumber': serialNumber,
    'supportsBattery': supportsBattery,
    'supportsScreen': supportsScreen,
    'screenType': screenType.wire,
    'screenWidth': screenWidth,
    'screenHeight': screenHeight,
    'mcuDescription': mcuDescription,
  };

  String get vendorIdString => _hex32(vendorId);
  String get modelIdString => _hex32(modelId);
  String get productIdString => _hex32(productId);
  String get hardwareVersionString => _hex32(hardwareVersion);

  static String _hex32(int value) =>
      '0x${(value & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0').toUpperCase()}';
}

/// Trạng thái động từ DEVICE_STATUS (0x04).
class DeviceStatus {
  static const int batteryPresentFlag = 1 << 0;
  static const int chargingFlag = 1 << 1;
  static const int screenOnFlag = 1 << 2;
  static const int lowPowerFlag = 1 << 3;

  final int flags;
  final int? batteryPercent;
  final int? supplyMillivolts;
  final double? temperatureCelsius;
  final int pinState;
  final Duration uptime;
  final int freeHeapBytes;
  final DateTime receivedAt;

  const DeviceStatus({
    required this.flags,
    required this.batteryPercent,
    required this.supplyMillivolts,
    required this.temperatureCelsius,
    required this.pinState,
    required this.uptime,
    required this.freeHeapBytes,
    required this.receivedAt,
  });

  bool get batteryPresent => flags & batteryPresentFlag != 0;
  bool get charging => flags & chargingFlag != 0;
  bool get screenOn => flags & screenOnFlag != 0;
  bool get lowPower => flags & lowPowerFlag != 0;
}

/// Snapshot trạng thái BLE cho UI.
class BleStatus {
  final BleConnectionState state;
  final DiscoveredDevice? device;
  final DeviceInfo? info;
  final DeviceSystemInfo? systemInfo;
  final DeviceStatus? deviceStatus;
  final int? rssi;
  final int? mtu;
  final int reconnectInSeconds;

  const BleStatus({
    this.state = BleConnectionState.unpaired,
    this.device,
    this.info,
    this.systemInfo,
    this.deviceStatus,
    this.rssi,
    this.mtu,
    this.reconnectInSeconds = 0,
  });

  BleStatus copyWith({
    BleConnectionState? state,
    DiscoveredDevice? device,
    DeviceInfo? info,
    DeviceSystemInfo? systemInfo,
    DeviceStatus? deviceStatus,
    int? rssi,
    int? mtu,
    int? reconnectInSeconds,
  }) {
    return BleStatus(
      state: state ?? this.state,
      device: device ?? this.device,
      info: info ?? this.info,
      systemInfo: systemInfo ?? this.systemInfo,
      deviceStatus: deviceStatus ?? this.deviceStatus,
      rssi: rssi ?? this.rssi,
      mtu: mtu ?? this.mtu,
      reconnectInSeconds: reconnectInSeconds ?? this.reconnectInSeconds,
    );
  }
}
