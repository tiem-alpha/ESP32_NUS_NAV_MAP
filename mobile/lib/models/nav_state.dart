import 'geo_point.dart';
import 'maneuver_type.dart';
import 'route_model.dart';
import 'traffic_sign.dart';

/// Pha của state machine dẫn đường (§4.3).
/// Wire value khớp NAV_STATE (0x14) gửi xuống HUD.
enum NavPhase {
  idle(0),
  routing(1),
  navigating(2),
  rerouting(3),
  arrived(4);

  final int wire;
  const NavPhase(this.wire);
}

/// Snapshot trạng thái dẫn đường tại một thời điểm — **single source of truth**
/// mà cả UI (S4) lẫn BLE Bridge cùng render (§2.2). Immutable, copyWith để cập nhật.
class NavSnapshot {
  final NavPhase phase;
  final RouteModel? route;

  /// Index maneuver hiện tại trong route.allManeuvers.
  final int currentManeuverIndex;

  final Maneuver? currentManeuver;
  final Maneuver? nextManeuver;

  /// Khoảng cách (m) tới điểm rẽ hiện tại.
  final double distanceToManeuverM;

  /// Tổng khoảng cách (m) còn lại tới đích.
  final double distanceRemainingM;

  /// Thời gian còn lại (giây).
  final double etaSeconds;

  /// Vị trí GPS đã map-match lên tuyến.
  final GeoPoint? matchedPosition;
  final GeoPoint? currentPosition;
  final double routeProgressM;
  final double bearing; // hướng tuyến phía trước/camera, độ
  final double speedKmh; // tốc độ hiện tại

  /// Tốc độ giới hạn hiện hành (km/h), 0 = không rõ.
  final int speedLimitKmh;
  final bool isOverSpeed;

  /// GPS yếu (< 4 vệ tinh hoặc accuracy > 30 m) — §11.6.
  final bool gpsWeak;

  /// Biển báo sắp tới (đã trong tầm cảnh báo).
  final TrafficSign? approachingSign;

  const NavSnapshot({
    this.phase = NavPhase.idle,
    this.route,
    this.currentManeuverIndex = 0,
    this.currentManeuver,
    this.nextManeuver,
    this.distanceToManeuverM = 0,
    this.distanceRemainingM = 0,
    this.etaSeconds = 0,
    this.matchedPosition,
    this.currentPosition,
    this.routeProgressM = 0,
    this.bearing = 0,
    this.speedKmh = 0,
    this.speedLimitKmh = 0,
    this.isOverSpeed = false,
    this.gpsWeak = false,
    this.approachingSign,
  });

  bool get isActive =>
      phase == NavPhase.navigating || phase == NavPhase.rerouting;

  NavSnapshot copyWith({
    NavPhase? phase,
    RouteModel? route,
    int? currentManeuverIndex,
    Maneuver? currentManeuver,
    Maneuver? nextManeuver,
    double? distanceToManeuverM,
    double? distanceRemainingM,
    double? etaSeconds,
    GeoPoint? matchedPosition,
    GeoPoint? currentPosition,
    double? routeProgressM,
    double? bearing,
    double? speedKmh,
    int? speedLimitKmh,
    bool? isOverSpeed,
    bool? gpsWeak,
    TrafficSign? approachingSign,
    bool clearSign = false,
  }) {
    return NavSnapshot(
      phase: phase ?? this.phase,
      route: route ?? this.route,
      currentManeuverIndex: currentManeuverIndex ?? this.currentManeuverIndex,
      currentManeuver: currentManeuver ?? this.currentManeuver,
      nextManeuver: nextManeuver ?? this.nextManeuver,
      distanceToManeuverM: distanceToManeuverM ?? this.distanceToManeuverM,
      distanceRemainingM: distanceRemainingM ?? this.distanceRemainingM,
      etaSeconds: etaSeconds ?? this.etaSeconds,
      matchedPosition: matchedPosition ?? this.matchedPosition,
      currentPosition: currentPosition ?? this.currentPosition,
      routeProgressM: routeProgressM ?? this.routeProgressM,
      bearing: bearing ?? this.bearing,
      speedKmh: speedKmh ?? this.speedKmh,
      speedLimitKmh: speedLimitKmh ?? this.speedLimitKmh,
      isOverSpeed: isOverSpeed ?? this.isOverSpeed,
      gpsWeak: gpsWeak ?? this.gpsWeak,
      approachingSign: clearSign
          ? null
          : (approachingSign ?? this.approachingSign),
    );
  }

  ManeuverType get currentManeuverType =>
      currentManeuver?.type ?? ManeuverType.straight;
}
