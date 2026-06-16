import 'package:intl/intl.dart';

/// Helper định dạng tiếng Việt (dấu phẩy thập phân) cho khoảng cách, thời gian,
/// ETA — dùng chung S3/S4. (§11.5, §11.6)
class UiFormat {
  UiFormat._();

  /// "350 m" / "8,5 km".
  static String distance(double meters) {
    if (meters.isNaN || meters.isInfinite || meters < 0) return '0 m';
    if (meters < 1000) {
      // làm tròn 10 m cho số nhỏ đỡ "nhảy".
      final rounded = (meters / 10).round() * 10;
      return '$rounded m';
    }
    final km = meters / 1000;
    final s = km < 10
        ? km.toStringAsFixed(1).replaceAll('.', ',')
        : km.round().toString();
    return '$s km';
  }

  /// "24 phút" (làm tròn phút, tối thiểu 1 phút khi còn quãng).
  static String duration(double seconds) {
    if (seconds.isNaN || seconds.isInfinite || seconds <= 0) return '0 phút';
    final mins = (seconds / 60).round();
    if (mins < 1) return '1 phút';
    if (mins < 60) return '$mins phút';
    final h = mins ~/ 60;
    final m = mins % 60;
    return m == 0 ? '$h giờ' : '$h giờ $m phút';
  }

  /// "14:32" — đồng hồ giờ tới nơi (now + seconds còn lại).
  static String eta(double remainingSeconds) {
    if (remainingSeconds.isNaN || remainingSeconds.isInfinite) {
      remainingSeconds = 0;
    }
    final arrival =
        DateTime.now().add(Duration(seconds: remainingSeconds.round()));
    return DateFormat('HH:mm').format(arrival);
  }

  /// "RSSI -61 dBm".
  static String rssi(int? value) => value == null ? '— dBm' : '$value dBm';
}

/// API ngắn gọn theo mô tả task.
String formatDistance(double meters) => UiFormat.distance(meters);
String formatDuration(double seconds) => UiFormat.duration(seconds);
String formatEta(double seconds) => UiFormat.eta(seconds);
