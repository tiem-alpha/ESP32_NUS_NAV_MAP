/// Enum maneuver **dùng chung với firmware** (`nav_proto.h`, §6.3).
///
/// Thứ tự & giá trị số PHẢI ổn định và khớp `maneuver_e` của thiết bị nhúng —
/// đây là wire value gửi qua NUS. Không reorder, chỉ append cuối nếu mở rộng.
enum ManeuverType {
  depart(0),
  straight(1),
  turnSlightLeft(2),
  turnLeft(3),
  turnSharpLeft(4),
  uturn(5),
  turnSharpRight(6),
  turnRight(7),
  turnSlightRight(8),
  roundabout(9),
  exitLeft(10),
  exitRight(11),
  merge(12),
  ferry(13),
  arrive(14),
  arriveLeft(15),
  arriveRight(16);

  /// Giá trị wire (byte gửi xuống thiết bị).
  final int wire;
  const ManeuverType(this.wire);

  static ManeuverType fromWire(int v) =>
      values.firstWhere((e) => e.wire == v, orElse: () => straight);

  bool get isArrival =>
      this == arrive || this == arriveLeft || this == arriveRight;

  /// Tên asset SVG icon maneuver (`assets/icons/maneuvers/<name>.svg`).
  String get iconAsset => 'assets/icons/maneuvers/$name.svg';

  /// Map từ mã maneuver `type` (int) của Valhalla sang enum nội bộ.
  ///
  /// Valhalla type reference: 0 none/1 start ... — ta map theo nhóm hành vi.
  /// (Bảng đầy đủ ở route adapter; helper này giữ logic tập trung.)
  static ManeuverType fromValhalla(int type) {
    switch (type) {
      case 1: // start
      case 2: // start_right
      case 3: // start_left
        return depart;
      case 4: // destination
        return arrive;
      case 5: // destination_right
        return arriveRight;
      case 6: // destination_left
        return arriveLeft;
      case 8: // continue
        return straight;
      case 9: // slight right
        return turnSlightRight;
      case 10: // right
        return turnRight;
      case 11: // sharp right
        return turnSharpRight;
      case 12: // uturn right
      case 13: // uturn left
        return uturn;
      case 14: // sharp left
        return turnSharpLeft;
      case 15: // left
        return turnLeft;
      case 16: // slight left
        return turnSlightLeft;
      case 17: // ramp straight
        return straight;
      case 18: // ramp right
        return exitRight;
      case 19: // ramp left
        return exitLeft;
      case 20: // exit right
        return exitRight;
      case 21: // exit left
        return exitLeft;
      case 22: // stay straight
      case 23: // stay right
      case 24: // stay left
        return straight;
      case 25: // merge
      case 37: // merge right
      case 38: // merge left
        return merge;
      case 26: // roundabout enter
      case 27: // roundabout exit
        return roundabout;
      case 28: // ferry enter
      case 29: // ferry exit
        return ferry;
      default:
        return straight;
    }
  }
}
