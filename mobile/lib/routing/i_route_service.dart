import '../models/geo_point.dart';
import '../models/route_model.dart';
import '../models/travel_profile.dart';

/// Tuỳ chọn định tuyến (§4.2).
class RouteOptions {
  final bool avoidTolls;
  final bool avoidHighways;
  final String language;

  const RouteOptions({
    this.avoidTolls = false,
    this.avoidHighways = false,
    this.language = 'vi-VN',
  });
}

/// Lỗi định tuyến để UI hiển thị state lỗi (§11.9).
class RouteException implements Exception {
  final String message;
  const RouteException(this.message);
  @override
  String toString() => 'RouteException: $message';
}

/// Abstraction routing engine — cho phép swap Valhalla ↔ OSRM/GraphHopper
/// mà không đụng Navigation Engine (§3.2).
abstract interface class IRouteService {
  /// Tính tuyến (kèm alternatives nếu engine hỗ trợ). Phần tử [0] = tuyến chính.
  Future<List<RouteModel>> route({
    required GeoPoint origin,
    required GeoPoint destination,
    required TravelProfile profile,
    RouteOptions options = const RouteOptions(),
    bool alternatives = true,
  });
}
