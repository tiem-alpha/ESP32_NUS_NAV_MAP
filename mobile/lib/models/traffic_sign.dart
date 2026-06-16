/// Loại biển báo gửi xuống HUD (TRAFFIC_SIGN 0x13, field `sign_type`).
/// Wire value ổn định — dùng chung firmware.
enum SignType {
  unknown(0),
  speedLimit(1),
  speedCamera(2),
  noEntry(3),
  noLeftTurn(4),
  noRightTurn(5),
  noUturn(6),
  stop(7),
  yield_(8),
  railwayCrossing(9),
  schoolZone(10),
  redLightCamera(11);

  final int wire;
  const SignType(this.wire);

  static SignType fromWire(int v) =>
      values.firstWhere((e) => e.wire == v, orElse: () => unknown);

  String get iconAsset => 'assets/icons/signs/$name.svg';
}

/// Biển báo gắn vào "linear reference" của tuyến (offset mét từ điểm đầu) — §4.4.
class TrafficSign {
  final SignType type;

  /// Giá trị kèm theo: vd tốc độ giới hạn (km/h) cho [SignType.speedLimit].
  final int value;

  /// Offset (mét) dọc theo tuyến tính từ điểm đầu — dùng để bắn cảnh báo sớm.
  final double offsetM;

  const TrafficSign({
    required this.type,
    required this.offsetM,
    this.value = 0,
  });
}
