import 'dart:math' as math;

import 'package:dio/dio.dart';

import '../core/constants.dart';
import '../models/geo_point.dart';
import '../models/route_model.dart';
import '../models/traffic_sign.dart';
import 'i_sign_service.dart';

/// Lấy biển báo dọc tuyến từ Overpass API rồi gắn offset tuyến tính — §4.4.
///
/// Best-effort: lỗi mạng/parse → trả `const []`, không throw.
class OverpassSignService implements ISignService {
  /// Bán kính buffer (mét) quanh hành lang tuyến khi query node.
  static const double _corridorBufferM = 30.0;

  /// Ngưỡng (mét) tối đa từ node tới tuyến để coi là "thuộc tuyến".
  static const double _snapThresholdM = 40.0;

  final Dio _dio;
  OverpassSignService(this._dio);

  @override
  Future<List<TrafficSign>> signsAlongRoute(RouteModel route) async {
    final geometry = route.geometry;
    if (geometry.length < 2) return const [];

    try {
      // Bounding box quanh tuyến (mở rộng một chút để bắt biển ven đường).
      final bbox = _routeBbox(geometry, _corridorBufferM);

      // Lấy các node biển báo trong bbox: tốc độ, camera, biển báo, cấm rẽ.
      final query =
          '[out:json][timeout:25];'
          '('
          'node["maxspeed"]($bbox);'
          'node["highway"="speed_camera"]($bbox);'
          'node["traffic_sign"]($bbox);'
          'node["highway"="stop"]($bbox);'
          'node["highway"="give_way"]($bbox);'
          'node["highway"="crossing"]["railway"]($bbox);'
          'node["railway"="level_crossing"]($bbox);'
          ');'
          'out body;';

      final resp = await _dio.post<dynamic>(
        AppConfig.overpassUrl,
        data: {'data': query},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );

      final data = _asMap(resp.data);
      final elements = data['elements'] as List<dynamic>? ?? const [];

      // Khoảng cách tích luỹ tới đầu mỗi đoạn của tuyến (linear reference).
      final cumulative = _cumulativeDistances(geometry);

      final signs = <TrafficSign>[];
      for (final el in elements) {
        try {
          final m = _asMap(el);
          if (m['type'] != 'node') continue;
          final nlat = (m['lat'] as num?)?.toDouble();
          final nlon = (m['lon'] as num?)?.toDouble();
          if (nlat == null || nlon == null) continue;

          final tags = _asMap(m['tags']);
          final parsed = _classify(tags);
          if (parsed == null) continue;

          final node = GeoPoint(nlat, nlon);
          final ref = _linearRef(node, geometry, cumulative);
          // Quá xa tuyến → bỏ (biển ở đường khác cùng bbox).
          if (ref.distanceM > _snapThresholdM) continue;

          signs.add(
            TrafficSign(
              type: parsed.type,
              value: parsed.value,
              offsetM: ref.offsetM,
            ),
          );
        } catch (_) {
          continue;
        }
      }

      signs.sort((a, b) => a.offsetM.compareTo(b.offsetM));
      return signs;
    } catch (_) {
      return const [];
    }
  }

  // ── Phân loại tag OSM → SignType + value ──────────────────────────────

  _ParsedSign? _classify(Map<String, dynamic> tags) {
    final highway = tags['highway']?.toString();
    final railway = tags['railway']?.toString();
    final trafficSign = tags['traffic_sign']?.toString().toLowerCase();
    final maxspeed = tags['maxspeed']?.toString();

    // Camera bắn tốc độ.
    if (highway == 'speed_camera') {
      return const _ParsedSign(SignType.speedCamera, 0);
    }
    // Camera đèn đỏ (đôi khi gắn vào traffic_sign / enforcement).
    if (trafficSign != null && trafficSign.contains('red_light')) {
      return const _ParsedSign(SignType.redLightCamera, 0);
    }
    // Giao cắt đường sắt.
    if (railway == 'level_crossing' ||
        (highway == 'crossing' && railway != null)) {
      return const _ParsedSign(SignType.railwayCrossing, 0);
    }
    // Stop / nhường đường.
    if (highway == 'stop') return const _ParsedSign(SignType.stop, 0);
    if (highway == 'give_way') return const _ParsedSign(SignType.yield_, 0);

    // Giới hạn tốc độ (maxspeed=50, "50 km/h", "RO:urban"…).
    if (maxspeed != null) {
      final v = _parseSpeed(maxspeed);
      if (v != null) return _ParsedSign(SignType.speedLimit, v);
    }

    // Suy luận từ traffic_sign chuẩn (VN / quốc tế).
    if (trafficSign != null && trafficSign.isNotEmpty) {
      // maxspeed encode trong traffic_sign, vd "DE:274[50]".
      final v = _speedFromTrafficSign(trafficSign);
      if (v != null) return _ParsedSign(SignType.speedLimit, v);
      if (trafficSign.contains('no_entry')) {
        return const _ParsedSign(SignType.noEntry, 0);
      }
      if (trafficSign.contains('no_left_turn')) {
        return const _ParsedSign(SignType.noLeftTurn, 0);
      }
      if (trafficSign.contains('no_right_turn')) {
        return const _ParsedSign(SignType.noRightTurn, 0);
      }
      if (trafficSign.contains('no_u_turn')) {
        return const _ParsedSign(SignType.noUturn, 0);
      }
      if (trafficSign.contains('stop')) {
        return const _ParsedSign(SignType.stop, 0);
      }
      if (trafficSign.contains('give_way') ||
          trafficSign.contains('yield')) {
        return const _ParsedSign(SignType.yield_, 0);
      }
      if (trafficSign.contains('school')) {
        return const _ParsedSign(SignType.schoolZone, 0);
      }
    }

    return null;
  }

  /// Parse "50", "50 km/h", "50 mph" → km/h (int). Bỏ giá trị phi số.
  int? _parseSpeed(String raw) {
    final s = raw.trim().toLowerCase();
    final match = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(s);
    if (match == null) return null;
    final n = double.tryParse(match.group(1)!);
    if (n == null || n <= 0) return null;
    // Đổi mph → km/h nếu cần.
    final kmh = s.contains('mph') ? n * 1.60934 : n;
    return kmh.round();
  }

  /// Trích tốc độ từ traffic_sign dạng "XX:274[50]" hoặc chứa "maxspeed".
  int? _speedFromTrafficSign(String s) {
    final bracket = RegExp(r'\[(\d+)\]').firstMatch(s);
    if (bracket != null) {
      return int.tryParse(bracket.group(1)!);
    }
    if (s.contains('maxspeed')) {
      final m = RegExp(r'(\d+)').firstMatch(s);
      if (m != null) return int.tryParse(m.group(1)!);
    }
    return null;
  }

  // ── Linear referencing ────────────────────────────────────────────────

  /// Khoảng cách tích luỹ tới đầu mỗi điểm geometry (cumulative[0] = 0).
  List<double> _cumulativeDistances(List<GeoPoint> geometry) {
    final cum = List<double>.filled(geometry.length, 0.0);
    for (var i = 1; i < geometry.length; i++) {
      cum[i] = cum[i - 1] + geometry[i - 1].distanceTo(geometry[i]);
    }
    return cum;
  }

  /// Chiếu [node] lên tuyến, trả về offset dọc tuyến (mét) và khoảng cách
  /// vuông góc tới tuyến (mét).
  _LinearRef _linearRef(
    GeoPoint node,
    List<GeoPoint> geometry,
    List<double> cumulative,
  ) {
    var bestDist = double.infinity;
    var bestOffset = 0.0;

    for (var i = 0; i < geometry.length - 1; i++) {
      final a = geometry[i];
      final b = geometry[i + 1];
      final proj = _projectOntoSegment(node, a, b);
      final d = node.distanceTo(proj.point);
      if (d < bestDist) {
        bestDist = d;
        // offset = khoảng cách tới đầu đoạn + phần đã đi trong đoạn.
        bestOffset = cumulative[i] + a.distanceTo(proj.point);
      }
    }

    return _LinearRef(offsetM: bestOffset, distanceM: bestDist);
  }

  /// Chiếu điểm [p] lên đoạn [a]→[b] (xấp xỉ phẳng equirectangular — đủ chính
  /// xác ở khoảng cách ngắn). Trả về điểm chiếu đã clamp trong đoạn.
  _Projection _projectOntoSegment(GeoPoint p, GeoPoint a, GeoPoint b) {
    final latRef = a.lat * math.pi / 180;
    final cosLat = math.cos(latRef);

    double x(GeoPoint g) => g.lng * cosLat;
    double y(GeoPoint g) => g.lat;

    final ax = x(a), ay = y(a);
    final bx = x(b), by = y(b);
    final px = x(p), py = y(p);

    final dx = bx - ax;
    final dy = by - ay;
    final lenSq = dx * dx + dy * dy;
    if (lenSq == 0) {
      return _Projection(a); // đoạn suy biến
    }
    var t = ((px - ax) * dx + (py - ay) * dy) / lenSq;
    t = t.clamp(0.0, 1.0);

    final projLng = (ax + t * dx) / cosLat;
    final projLat = ay + t * dy;
    return _Projection(GeoPoint(projLat, projLng));
  }

  /// Bounding box "south,west,north,east" mở rộng [bufferM] mét quanh tuyến.
  String _routeBbox(List<GeoPoint> geometry, double bufferM) {
    var minLat = geometry.first.lat;
    var maxLat = geometry.first.lat;
    var minLng = geometry.first.lng;
    var maxLng = geometry.first.lng;
    for (final g in geometry) {
      if (g.lat < minLat) minLat = g.lat;
      if (g.lat > maxLat) maxLat = g.lat;
      if (g.lng < minLng) minLng = g.lng;
      if (g.lng > maxLng) maxLng = g.lng;
    }
    // Đổi buffer mét → độ.
    final latBuf = bufferM / 111320.0;
    final midLat = (minLat + maxLat) / 2;
    final cosLat = math.cos(midLat * math.pi / 180).abs().clamp(0.01, 1.0);
    final lngBuf = bufferM / (111320.0 * cosLat);

    final s = (minLat - latBuf).toStringAsFixed(7);
    final w = (minLng - lngBuf).toStringAsFixed(7);
    final n = (maxLat + latBuf).toStringAsFixed(7);
    final e = (maxLng + lngBuf).toStringAsFixed(7);
    return '$s,$w,$n,$e';
  }

  Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return const {};
  }
}

/// Kết quả phân loại biển báo (type + value kèm theo).
class _ParsedSign {
  final SignType type;
  final int value;
  const _ParsedSign(this.type, this.value);
}

/// Kết quả chiếu node lên tuyến.
class _LinearRef {
  final double offsetM;
  final double distanceM;
  const _LinearRef({required this.offsetM, required this.distanceM});
}

/// Điểm chiếu trên một đoạn.
class _Projection {
  final GeoPoint point;
  const _Projection(this.point);
}
