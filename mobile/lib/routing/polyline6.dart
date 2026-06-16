import '../models/geo_point.dart';

/// Decode chuỗi polyline mã hoá theo thuật toán Google, với độ chính xác tuỳ chọn.
///
/// Valhalla dùng precision 1e-6 (chia cho 1e6), khác Google Maps mặc định 1e-5.
List<GeoPoint> decodePolyline(String encoded, {double precision = 1e6}) {
  final points = <GeoPoint>[];
  int index = 0;
  final len = encoded.length;
  int lat = 0;
  int lng = 0;

  while (index < len) {
    int shift = 0;
    int result = 0;
    int b;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    final dLat = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
    lat += dLat;

    shift = 0;
    result = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    final dLng = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
    lng += dLng;

    points.add(GeoPoint(lat / precision, lng / precision));
  }
  return points;
}

/// Decode polyline6 (Valhalla shape) — precision 1e-6.
List<GeoPoint> decodePolyline6(String encoded) =>
    decodePolyline(encoded, precision: 1e6);
