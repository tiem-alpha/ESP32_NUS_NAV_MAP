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

  /// MTU mong muốn khi negotiate trên Android (§5.2). iOS tự negotiate.
  static const int desiredMtu = 247;
}
