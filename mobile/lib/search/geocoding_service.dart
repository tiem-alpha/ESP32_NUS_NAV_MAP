import 'dart:math' as math;

import 'package:dio/dio.dart';

import '../core/constants.dart';
import '../models/geo_point.dart';
import '../models/place.dart';
import 'i_geocoding_service.dart';

/// Geocoding: Goong (nếu có API key) hoặc fallback Nominatim — §3.2, §4.1.
class GeocodingService implements IGeocodingService {
  static const _nominatimLimit = 10;
  static const _nominatimViewboxRadiusKm = 50.0;

  final Dio _dio;
  GeocodingService(this._dio);

  bool get _useGoong => AppConfig.goongApiKey.isNotEmpty;

  @override
  Future<List<Place>> search(String query, {GeoPoint? near}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    try {
      return _useGoong
          ? await _searchGoong(q, near)
          : await _searchNominatim(q, near);
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<Place?> reverse(GeoPoint point) async {
    try {
      return _useGoong
          ? await _reverseGoong(point)
          : await _reverseNominatim(point);
    } catch (_) {
      return null;
    }
  }

  // ── Goong ───────────────────────────────────────────────────────────

  Future<List<Place>> _searchGoong(String q, GeoPoint? near) async {
    final params = <String, dynamic>{
      'api_key': AppConfig.goongApiKey,
      'input': q,
    };
    if (near != null) {
      params['location'] = '${near.lat},${near.lng}';
    }
    final resp = await _dio.get<dynamic>(
      '${AppConfig.goongBaseUrl}/Place/AutoComplete',
      queryParameters: params,
    );
    final data = _asMap(resp.data);
    final predictions = data['predictions'] as List<dynamic>? ?? const [];
    final places = <Place>[];
    for (final p in predictions) {
      try {
        final pred = p as Map<String, dynamic>;
        final placeId = pred['place_id']?.toString() ?? '';
        final structured =
            pred['structured_formatting'] as Map<String, dynamic>?;
        final name =
            structured?['main_text']?.toString() ??
            pred['description']?.toString() ??
            '';
        final address =
            structured?['secondary_text']?.toString() ??
            pred['description']?.toString() ??
            '';
        final detail = await _goongDetail(placeId);
        if (detail == null) continue;
        places.add(
          Place(id: placeId, name: name, address: address, location: detail),
        );
      } catch (_) {
        continue;
      }
    }
    return _rankPlaces(q, places, near);
  }

  Future<GeoPoint?> _goongDetail(String placeId) async {
    if (placeId.isEmpty) return null;
    final resp = await _dio.get<dynamic>(
      '${AppConfig.goongBaseUrl}/Place/Detail',
      queryParameters: {'api_key': AppConfig.goongApiKey, 'place_id': placeId},
    );
    final data = _asMap(resp.data);
    final result = data['result'] as Map<String, dynamic>?;
    final loc = result?['geometry']?['location'] as Map<String, dynamic>?;
    if (loc == null) return null;
    final lat = (loc['lat'] as num?)?.toDouble();
    final lng = (loc['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;
    return GeoPoint(lat, lng);
  }

  Future<Place?> _reverseGoong(GeoPoint point) async {
    final resp = await _dio.get<dynamic>(
      '${AppConfig.goongBaseUrl}/Geocode',
      queryParameters: {
        'api_key': AppConfig.goongApiKey,
        'latlng': '${point.lat},${point.lng}',
      },
    );
    final data = _asMap(resp.data);
    final results = data['results'] as List<dynamic>? ?? const [];
    if (results.isEmpty) return null;
    final r = results.first as Map<String, dynamic>;
    final formatted = r['formatted_address']?.toString() ?? '';
    return Place(
      id: r['place_id']?.toString() ?? '${point.lat},${point.lng}',
      name: formatted.split(',').first.trim(),
      address: formatted,
      location: point,
    );
  }

  // ── Nominatim ───────────────────────────────────────────────────────

  Future<List<Place>> _searchNominatim(String q, GeoPoint? near) async {
    final places = <Place>[];
    final seen = <String>{};

    for (final params in _nominatimSearchAttempts(q, near)) {
      final batch = await _requestNominatimSearch(params);
      for (final place in batch) {
        if (seen.add(place.id)) {
          places.add(place);
          if (places.length >= _nominatimLimit) {
            return _rankPlaces(q, places, near);
          }
        }
      }
      if (batch.isNotEmpty) break;
    }

    return _rankPlaces(q, places, near);
  }

  Iterable<Map<String, dynamic>> _nominatimSearchAttempts(
    String q,
    GeoPoint? near,
  ) sync* {
    final localBase = _nominatimBaseParams(near, bounded: true);
    final base = _nominatimBaseParams(near);
    final countryCodes = AppConfig.nominatimCountryCodes.trim();
    final relaxedAddressQuery = _relaxedAddressQuery(q);

    if (near != null) {
      yield {
        ...localBase,
        'q': q,
        if (countryCodes.isNotEmpty) 'countrycodes': countryCodes,
      };

      if (relaxedAddressQuery != null) {
        yield {
          ...localBase,
          'q': relaxedAddressQuery,
          if (countryCodes.isNotEmpty) 'countrycodes': countryCodes,
        };
      }
    }

    yield {
      ...base,
      'q': q,
      if (countryCodes.isNotEmpty) 'countrycodes': countryCodes,
    };

    if (!_hasCountryHint(q)) {
      yield {
        ...base,
        'q': '$q, Vietnam',
        if (countryCodes.isNotEmpty) 'countrycodes': countryCodes,
      };
    }

    if (countryCodes.isNotEmpty) {
      yield {...base, 'q': q};
    }
  }

  Map<String, dynamic> _nominatimBaseParams(
    GeoPoint? near, {
    bool bounded = false,
  }) {
    final params = <String, dynamic>{
      'format': 'jsonv2',
      'addressdetails': '1',
      'namedetails': '1',
      'limit': _nominatimLimit.toString(),
      'accept-language': AppConfig.nominatimAcceptLanguage,
    };
    final viewbox = _nominatimViewbox(near);
    if (viewbox != null) {
      params['viewbox'] = viewbox;
      params['bounded'] = bounded ? '1' : '0';
    }
    return params;
  }

  String? _nominatimViewbox(GeoPoint? near) {
    if (near == null) return null;
    final latDelta = _nominatimViewboxRadiusKm / 110.574;
    final cosLat = math.cos(near.lat * math.pi / 180).abs().clamp(0.01, 1.0);
    final lngDelta = _nominatimViewboxRadiusKm / (111.320 * cosLat);
    final west = _clampLng(near.lng - lngDelta);
    final east = _clampLng(near.lng + lngDelta);
    final north = (near.lat + latDelta).clamp(-90.0, 90.0);
    final south = (near.lat - latDelta).clamp(-90.0, 90.0);
    return '$west,$north,$east,$south';
  }

  double _clampLng(double lng) => lng.clamp(-180.0, 180.0);

  bool _hasCountryHint(String q) {
    final lower = q.toLowerCase();
    return lower.contains('vietnam') ||
        lower.contains('viet nam') ||
        lower.contains(', vn') ||
        lower.endsWith(' vn');
  }

  String? _relaxedAddressQuery(String q) {
    final compact = q.replaceAll(RegExp(r'\s+'), ' ').trim();
    for (final pattern in [
      RegExp(
        r'^(?:số|so)\s+\d+[a-zA-Z]?(?:[\/-]\d+[a-zA-Z]?)?[\s,.-]+(.+)$',
        caseSensitive: false,
        unicode: true,
      ),
      RegExp(
        r'^\d+[a-zA-Z]?(?:[\/-]\d+[a-zA-Z]?)?[\s,.-]+(.+)$',
        caseSensitive: false,
      ),
    ]) {
      final match = pattern.firstMatch(compact);
      final relaxed = match?.group(1)?.trim();
      if (relaxed != null && relaxed.length >= 3) return relaxed;
    }
    return null;
  }

  Future<List<Place>> _requestNominatimSearch(
    Map<String, dynamic> params,
  ) async {
    final resp = await _dio.get<dynamic>(
      '${AppConfig.nominatimBaseUrl}/search',
      queryParameters: params,
      options: _nominatimOptions(),
    );
    final list = resp.data is List
        ? resp.data as List<dynamic>
        : const <dynamic>[];
    final places = <Place>[];
    for (final item in list) {
      try {
        final m = item as Map<String, dynamic>;
        final lat = double.tryParse(m['lat']?.toString() ?? '');
        final lon = double.tryParse(m['lon']?.toString() ?? '');
        if (lat == null || lon == null) continue;
        final display = m['display_name']?.toString() ?? '';
        final parts = display.split(',');
        final name = _nominatimName(
          m,
          parts.isNotEmpty ? parts.first.trim() : display,
        );
        final address = parts.length > 1
            ? parts.sublist(1).join(',').trim()
            : display;
        places.add(
          Place(
            id: _nominatimId(m, lat, lon),
            name: name,
            address: address,
            location: GeoPoint(lat, lon),
          ),
        );
      } catch (_) {
        continue;
      }
    }
    return places;
  }

  Future<Place?> _reverseNominatim(GeoPoint point) async {
    final resp = await _dio.get<dynamic>(
      '${AppConfig.nominatimBaseUrl}/reverse',
      queryParameters: {
        'lat': point.lat.toString(),
        'lon': point.lng.toString(),
        'format': 'jsonv2',
        'accept-language': AppConfig.nominatimAcceptLanguage,
      },
      options: _nominatimOptions(),
    );
    final m = _asMap(resp.data);
    final display = m['display_name']?.toString();
    if (display == null || display.isEmpty) return null;
    final parts = display.split(',');
    return Place(
      id: m['place_id']?.toString() ?? '${point.lat},${point.lng}',
      name: parts.isNotEmpty ? parts.first.trim() : display,
      address: display,
      location: point,
    );
  }

  Options _nominatimOptions() => Options(
    headers: {
      'User-Agent': AppConfig.nominatimUserAgent,
      'Accept-Language': AppConfig.nominatimAcceptLanguage,
    },
  );

  String _nominatimId(Map<String, dynamic> m, double lat, double lon) {
    final osmType = m['osm_type']?.toString();
    final osmId = m['osm_id']?.toString();
    if (osmType != null &&
        osmType.isNotEmpty &&
        osmId != null &&
        osmId.isNotEmpty) {
      return '$osmType:$osmId';
    }
    return m['place_id']?.toString() ?? '$lat,$lon';
  }

  String _nominatimName(Map<String, dynamic> m, String fallback) {
    final direct = m['name']?.toString();
    if (direct != null && direct.trim().isNotEmpty) return direct.trim();

    final namedetails = m['namedetails'];
    if (namedetails is Map) {
      for (final key in const [
        'name:vi',
        'name',
        'official_name',
        'alt_name',
      ]) {
        final value = namedetails[key]?.toString();
        if (value != null && value.trim().isNotEmpty) return value.trim();
      }
    }

    return fallback;
  }

  List<Place> _rankPlaces(String query, List<Place> places, GeoPoint? near) {
    if (places.length < 2) return places;

    final normalizedQuery = _normalizeSearchText(
      near == null ? query : _relaxedAddressQuery(query) ?? query,
    );
    final tokens = normalizedQuery
        .split(' ')
        .where((token) => token.length >= 2)
        .toList(growable: false);
    final ranked = <_RankedPlace>[
      for (var i = 0; i < places.length; i++)
        _RankedPlace(
          place: places[i],
          index: i,
          matchTier: _matchTier(normalizedQuery, tokens, places[i]),
          matchScore: _matchScore(normalizedQuery, tokens, places[i]),
          distanceM: near?.distanceTo(places[i].location),
        ),
    ];

    ranked.sort((a, b) {
      final tier = a.matchTier.compareTo(b.matchTier);
      if (tier != 0) return tier;

      if (a.distanceM != null && b.distanceM != null) {
        final distance = a.distanceM!.compareTo(b.distanceM!);
        if (distance != 0) return distance;
      }

      final score = b.matchScore.compareTo(a.matchScore);
      if (score != 0) return score;

      return a.index.compareTo(b.index);
    });

    return ranked.map((rankedPlace) => rankedPlace.place).toList();
  }

  int _matchTier(String normalizedQuery, List<String> tokens, Place place) {
    final name = _normalizeSearchText(place.name);
    final address = _normalizeSearchText(place.address);
    final full = '$name $address'.trim();

    if (_strongMatch(normalizedQuery, tokens, name)) return 0;
    if (_strongMatch(normalizedQuery, tokens, full)) return 1;
    if (_partialMatch(tokens, name)) return 2;
    if (_partialMatch(tokens, full)) return 3;
    return 4;
  }

  int _matchScore(String normalizedQuery, List<String> tokens, Place place) {
    final name = _normalizeSearchText(place.name);
    final address = _normalizeSearchText(place.address);
    final full = '$name $address'.trim();

    if (name == normalizedQuery) return 100;
    if (name.startsWith(normalizedQuery)) return 90;
    if (name.contains(normalizedQuery)) return 80;
    if (_containsAllTokens(tokens, name)) return 70;
    if (full.contains(normalizedQuery)) return 60;
    if (_containsAllTokens(tokens, full)) return 50;
    if (_partialMatch(tokens, name)) return 40;
    if (_partialMatch(tokens, full)) return 30;
    return 0;
  }

  bool _strongMatch(String normalizedQuery, List<String> tokens, String value) {
    if (normalizedQuery.isEmpty) return false;
    return value == normalizedQuery ||
        value.startsWith(normalizedQuery) ||
        value.contains(normalizedQuery) ||
        _containsAllTokens(tokens, value);
  }

  bool _containsAllTokens(List<String> tokens, String value) =>
      tokens.isNotEmpty && tokens.every(value.contains);

  bool _partialMatch(List<String> tokens, String value) =>
      tokens.any(value.contains);

  String _normalizeSearchText(String value) {
    final lower = value.toLowerCase();
    final buffer = StringBuffer();
    for (final char in lower.split('')) {
      buffer.write(_vietnameseAscii[char] ?? char);
    }
    return buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return const {};
  }
}

class _RankedPlace {
  final Place place;
  final int index;
  final int matchTier;
  final int matchScore;
  final double? distanceM;

  const _RankedPlace({
    required this.place,
    required this.index,
    required this.matchTier,
    required this.matchScore,
    required this.distanceM,
  });
}

const _vietnameseAscii = <String, String>{
  'à': 'a',
  'á': 'a',
  'ạ': 'a',
  'ả': 'a',
  'ã': 'a',
  'â': 'a',
  'ầ': 'a',
  'ấ': 'a',
  'ậ': 'a',
  'ẩ': 'a',
  'ẫ': 'a',
  'ă': 'a',
  'ằ': 'a',
  'ắ': 'a',
  'ặ': 'a',
  'ẳ': 'a',
  'ẵ': 'a',
  'è': 'e',
  'é': 'e',
  'ẹ': 'e',
  'ẻ': 'e',
  'ẽ': 'e',
  'ê': 'e',
  'ề': 'e',
  'ế': 'e',
  'ệ': 'e',
  'ể': 'e',
  'ễ': 'e',
  'ì': 'i',
  'í': 'i',
  'ị': 'i',
  'ỉ': 'i',
  'ĩ': 'i',
  'ò': 'o',
  'ó': 'o',
  'ọ': 'o',
  'ỏ': 'o',
  'õ': 'o',
  'ô': 'o',
  'ồ': 'o',
  'ố': 'o',
  'ộ': 'o',
  'ổ': 'o',
  'ỗ': 'o',
  'ơ': 'o',
  'ờ': 'o',
  'ớ': 'o',
  'ợ': 'o',
  'ở': 'o',
  'ỡ': 'o',
  'ù': 'u',
  'ú': 'u',
  'ụ': 'u',
  'ủ': 'u',
  'ũ': 'u',
  'ư': 'u',
  'ừ': 'u',
  'ứ': 'u',
  'ự': 'u',
  'ử': 'u',
  'ữ': 'u',
  'ỳ': 'y',
  'ý': 'y',
  'ỵ': 'y',
  'ỷ': 'y',
  'ỹ': 'y',
  'đ': 'd',
};
