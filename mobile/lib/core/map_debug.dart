import 'package:flutter/foundation.dart';

/// Log chẩn đoán riêng cho pipeline MapLibre → encoder → BLE → ESP32.
///
/// Debug build bật mặc định. Có thể ép bật/tắt ở mọi build bằng:
/// `--dart-define=MAP_DEBUG_LOGS=true|false`.
abstract final class MapDebug {
  static const enabled = bool.fromEnvironment(
    'MAP_DEBUG_LOGS',
    defaultValue: kDebugMode,
  );

  static void log(String stage, String message) {
    if (!enabled) return;
    debugPrint('[MapDebug][$stage] $message');
  }
}
