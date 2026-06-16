import '../models/geo_point.dart';
import '../models/place.dart';

/// Abstraction geocoding (Goong / Nominatim / Mapbox) — §3.2, §4.1.
abstract interface class IGeocodingService {
  /// Tìm địa điểm theo text (debounce 650 ms ở UI). [near] để ưu tiên gần.
  Future<List<Place>> search(String query, {GeoPoint? near});

  /// Reverse geocoding: toạ độ → địa chỉ (long-press drop pin §11.3).
  Future<Place?> reverse(GeoPoint point);
}
