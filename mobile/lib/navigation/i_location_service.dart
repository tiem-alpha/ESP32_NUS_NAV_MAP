import '../models/gps_fix.dart';

/// Trạng thái quyền vị trí cho full-screen gate (§11.9).
enum LocationPermissionStatus {
  granted,
  serviceDisabled,
  denied,
  deniedForever,
}

/// Abstraction nguồn vị trí (geolocator) — §4.3. Cho phép mock khi test
/// NavEngine bằng chuỗi GpsFix giả lập.
abstract interface class ILocationService {
  /// Xin quyền + kiểm tra dịch vụ vị trí. Trả về true nếu sẵn sàng.
  Future<bool> ensureReady();

  /// Kiểm tra trạng thái quyền hiện tại (không tự xin quyền) — dùng để hiện
  /// gate màn hình toàn cảnh khi chưa sẵn sàng (§11.9).
  Future<LocationPermissionStatus> checkStatus();

  /// Mở Cài đặt ứng dụng (khi quyền bị chặn vĩnh viễn).
  Future<void> openAppSettings();

  /// Mở Cài đặt dịch vụ vị trí hệ thống (khi GPS đang tắt).
  Future<void> openLocationSettings();

  /// Stream GPS fix ~1 Hz (đã lọc accuracy).
  Stream<GpsFix> positions();

  /// Lấy 1 fix hiện tại (cho camera bay tới khi mở app).
  Future<GpsFix?> current();
}
