import 'package:dio/dio.dart';

import '../core/constants.dart';
import '../models/geo_point.dart';
import '../models/road_segment.dart';

/// Lấy dữ liệu đường (road geometry) quanh một điểm từ Overpass API — §4.4.
///
/// Dùng để bắn xuống HUD (MAP_DATA) bản đồ đường thu nhỏ quanh xe.
/// Best-effort: mọi lỗi (mạng, parse) đều trả `const []`.
class OverpassRoadService {
  /// Giới hạn số segment trả về để chặn băng thông BLE (§4.4).
  static const int _maxSegments = 120;

  final Dio _dio;
  OverpassRoadService(this._dio);

  /// Truy vấn các đường quanh ([lat], [lng]) trong bán kính [radiusM] mét.
  Future<List<RoadSegment>> queryRoadsAround({
    required double lat,
    required double lng,
    required double radiusM,
  }) async {
    try {
      // Overpass QL: lấy mọi `way` có tag highway trong bán kính, kèm geometry.
      final query =
          '[out:json][timeout:25];'
          'way["highway"](around:${radiusM.toStringAsFixed(0)},'
          '${lat.toStringAsFixed(7)},${lng.toStringAsFixed(7)});'
          'out geom;';

      final resp = await _dio.post<dynamic>(
        AppConfig.overpassUrl,
        data: {'data': query},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );

      final data = _asMap(resp.data);
      final elements = data['elements'] as List<dynamic>? ?? const [];

      final segments = <RoadSegment>[];
      for (final el in elements) {
        if (segments.length >= _maxSegments) break;
        try {
          final m = _asMap(el);
          if (m['type'] != 'way') continue;

          final tags = _asMap(m['tags']);
          final highway = tags['highway']?.toString();
          if (highway == null || highway.isEmpty) continue;
          // Bỏ các lớp không phải đường xe chạy (footway, cycleway, path…).
          if (!_isVehicleHighway(highway)) continue;

          final geom = m['geometry'] as List<dynamic>? ?? const [];
          final points = <GeoPoint>[];
          for (final g in geom) {
            final gm = _asMap(g);
            final glat = (gm['lat'] as num?)?.toDouble();
            final glon = (gm['lon'] as num?)?.toDouble();
            if (glat == null || glon == null) continue;
            points.add(GeoPoint(glat, glon));
          }
          // Bỏ way không đủ điểm để vẽ một đoạn thẳng.
          if (points.length < 2) continue;

          segments.add(
            RoadSegment(
              type: HighwayType.fromOsmTag(highway),
              points: points,
            ),
          );
        } catch (_) {
          continue;
        }
      }
      return segments;
    } catch (_) {
      return const [];
    }
  }

  /// Chỉ giữ các lớp đường xe chạy (primary/secondary/tertiary/residential/
  /// service + trunk/motorway). Loại footway, cycleway, path, steps…
  bool _isVehicleHighway(String highway) {
    switch (highway) {
      case 'motorway':
      case 'motorway_link':
      case 'trunk':
      case 'trunk_link':
      case 'primary':
      case 'primary_link':
      case 'secondary':
      case 'secondary_link':
      case 'tertiary':
      case 'tertiary_link':
      case 'residential':
      case 'living_street':
      case 'unclassified':
      case 'service':
        return true;
      default:
        return false;
    }
  }

  Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return const {};
  }
}
