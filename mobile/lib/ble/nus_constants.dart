/// Hằng số Nordic UART Service (NUS) — §5.1.
///
/// RX/TX đặt **theo góc nhìn thiết bị nhúng** (giống firmware Nordic mẫu):
/// - App **ghi** vào RX char (`6E400002`) — phone → device.
/// - App **subscribe** TX char (`6E400003`, notify) — device → phone.
///
/// Các hằng này là wire-level, dùng chung spec với firmware; không đổi tuỳ tiện.
class Nus {
  Nus._();

  /// NUS Service UUID.
  static const String serviceUuid = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';

  /// RX characteristic — phone GHI vào (Write / Write No Response).
  static const String rxCharUuid = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E';

  /// TX characteristic — phone NHẬN (Notify).
  static const String txCharUuid = '6E400003-B5A3-F393-E0A9-E50E24DCCA9E';

  /// MTU 247 giữ mỗi ATT packet trong một HCI ACL packet 251 byte
  /// (4 byte L2CAP + 3 byte ATT + 244 byte dữ liệu). MTU 500 buộc controller
  /// ESP32 ráp nhiều ACL fragment và có thể gây lỗi `unfinished packet`.
  /// iOS tự negotiate và bridge vẫn dùng MTU thực tế nhỏ hơn nếu cần.
  static const int desiredMtu = 247;
}
