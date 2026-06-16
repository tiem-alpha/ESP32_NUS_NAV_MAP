import 'geo_point.dart';
import 'maneuver_type.dart';
import 'travel_profile.dart';

/// Một bước rẽ trong tuyến (đã chuẩn hoá nội bộ — §4.2).
class Maneuver {
  final ManeuverType type;
  final String instructionText; // tiếng Việt, để banner + TTS
  final String streetName;
  final GeoPoint location;
  final double distanceToNextM; // độ dài đoạn tới maneuver kế
  final double durationToNextS;
  final int? exitNumber; // vòng xuyến: lối ra thứ N
  final String? verbalPreText; // câu nhắc sớm (TTS), optional

  /// Index điểm bắt đầu của maneuver này trong [RouteModel.geometry].
  final int beginShapeIndex;

  const Maneuver({
    required this.type,
    required this.instructionText,
    required this.streetName,
    required this.location,
    required this.distanceToNextM,
    required this.durationToNextS,
    required this.beginShapeIndex,
    this.exitNumber,
    this.verbalPreText,
  });
}

/// Một leg (đoạn giữa 2 waypoint). MVP thường chỉ 1 leg.
class RouteLeg {
  final List<Maneuver> maneuvers;
  final double distanceM;
  final double durationS;

  const RouteLeg({
    required this.maneuvers,
    required this.distanceM,
    required this.durationS,
  });
}

/// Tuyến đường chuẩn hoá nội bộ — single source of truth cho UI + BLE (§2.2).
class RouteModel {
  final List<GeoPoint> geometry; // polyline6 đã decode
  final double distanceM;
  final double durationS;
  final List<RouteLeg> legs;
  final TravelProfile profile;

  /// Cảnh báo theo profile (vd "đoạn cấm xe máy") — hiển thị ở S3.
  final List<String> warnings;

  /// Tóm tắt tuyến (vd "Qua Đại lộ Thăng Long").
  final String summary;

  const RouteModel({
    required this.geometry,
    required this.distanceM,
    required this.durationS,
    required this.legs,
    required this.profile,
    this.warnings = const [],
    this.summary = '',
  });

  /// Toàn bộ maneuver phẳng (tiện cho step list & nav engine).
  List<Maneuver> get allManeuvers =>
      [for (final leg in legs) ...leg.maneuvers];

  GeoPoint get origin => geometry.first;
  GeoPoint get destination => geometry.last;
}
