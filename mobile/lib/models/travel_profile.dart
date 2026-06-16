/// 3 profile dẫn đường (G2). Giá trị `valhalla` map sang costing model
/// của Valhalla; `label` để hiển thị UI.
enum TravelProfile {
  auto('auto', 'Ô tô', '🚗'),
  motorScooter('motor_scooter', 'Xe máy', '🛵'),
  bicycle('bicycle', 'Xe đạp', '🚲');

  final String valhalla;
  final String label;
  final String emoji;

  const TravelProfile(this.valhalla, this.label, this.emoji);

  /// Ngưỡng lệch tuyến (mét) để trigger reroute — §4.3.
  double get offRouteThresholdM => this == TravelProfile.auto ? 35 : 25;

  /// Xe máy mặc định tránh cao tốc (§4.2 / S6 Settings).
  bool get avoidHighwaysDefault => this == TravelProfile.motorScooter;
}
