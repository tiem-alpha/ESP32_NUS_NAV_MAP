import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/geo_point.dart';
import '../models/road_segment.dart';

/// Lấy dữ liệu đường (road geometry) quanh một điểm từ Overpass API — §4.4.
///
/// Dùng để bắn xuống HUD (MAP_DATA) bản đồ đường thu nhỏ quanh xe.
/// Best-effort: mọi lỗi (mạng, parse) đều trả `const []`.
class OverpassRoadService {
  /// Parse tối đa bao nhiêu way từ Overpass. Không giới hạn sớm ở đây vì
  /// _encodeMapRoads sẽ sort theo khoảng cách và chỉ gửi 48 đường gần nhất.
  /// Giới hạn cao để tránh OOM trong trường hợp cực đoan (khu trung tâm đặc).
  static const int _maxSegments = 2000;

  // Thử lần lượt: primary trước, fallback khi 4xx/5xx.
  static const List<String> _endpoints = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.openstreetmap.fr/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
  ];

  final Dio _dio;
  OverpassRoadService(this._dio);

  /// Truy vấn các đường quanh ([lat], [lng]) trong bán kính [radiusM] mét.
  Future<List<RoadSegment>> queryRoadsAround({
    required double lat,
    required double lng,
    required double radiusM,
  }) async {
    // Overpass QL: lấy mọi `way` có tag highway trong bán kính, kèm geometry.
    // `out qt geom` = sort by quadtile (spatial proximity) trước khi trả,
    // giúp phần tử gần query center ra trước → parse 2000 đầu tiên đủ tin cậy.
    final query =
        '[out:json][timeout:20];'
        'way["highway"](around:${radiusM.toStringAsFixed(0)},'
        '${lat.toStringAsFixed(7)},${lng.toStringAsFixed(7)});'
        'out qt geom;';

    for (final url in _endpoints) {
      try {
        debugPrint('[Overpass] POST $url radius=${radiusM.round()}m center=$lat,$lng');
        final resp = await _dio.post<dynamic>(
          url,
          data: {'data': query},
          options: Options(
            contentType: Headers.formUrlEncodedContentType,
            headers: {
              'User-Agent': 'NavHUD/1.0 (nav-hud mobile app)',
              'Accept': '*/*',
            },
          ),
        );

        final data = _asMap(resp.data);
        final elements = data['elements'] as List<dynamic>? ?? const [];
        debugPrint('[Overpass] HTTP ${resp.statusCode} → ${elements.length} elements from $url');

        var skippedType = 0, skippedHighway = 0, skippedGeom = 0;
        final segments = <RoadSegment>[];
        for (final el in elements) {
          if (segments.length >= _maxSegments) break;
          try {
            final m = _asMap(el);
            if (m['type'] != 'way') { skippedType++; continue; }

            final tags = _asMap(m['tags']);
            final highway = tags['highway']?.toString();
            if (highway == null || highway.isEmpty) { skippedHighway++; continue; }
            // Bỏ các lớp không phải đường xe chạy (footway, cycleway, path…).
            if (!_isVehicleHighway(highway)) { skippedHighway++; continue; }

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
            if (points.length < 2) { skippedGeom++; continue; }

            segments.add(RoadSegment(type: HighwayType.fromOsmTag(highway), points: points));
          } catch (e) {
            debugPrint('[Overpass] element parse error: $e');
          }
        }
        debugPrint('[Overpass] parsed: ${segments.length} roads'
            ' (skip: type=$skippedType highway=$skippedHighway geom=$skippedGeom)');
        return segments;
      } catch (e) {
        debugPrint('[Overpass] $url FAILED: $e → try next endpoint');
        // Tiếp tục sang endpoint kế tiếp.
      }
    }
    debugPrint('[Overpass] All endpoints failed → return []');
    return const [];
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
