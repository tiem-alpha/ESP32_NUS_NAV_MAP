import 'package:dio/dio.dart';

import '../core/constants.dart';
import '../models/geo_point.dart';
import '../models/maneuver_type.dart';
import '../models/route_model.dart';
import '../models/travel_profile.dart';
import 'i_route_service.dart';
import 'polyline6.dart';

/// Định tuyến qua Valhalla (`/route`) — §3.2, §4.2.
///
/// Parse `trip.legs[].shape` (polyline6) + `trip.legs[].maneuvers[]` sang
/// model nội bộ [RouteModel]. Hỗ trợ alternatives qua `trip.alternates`.
class ValhallaRouteService implements IRouteService {
  final Dio _dio;
  ValhallaRouteService(this._dio);

  @override
  Future<List<RouteModel>> route({
    required GeoPoint origin,
    required GeoPoint destination,
    required TravelProfile profile,
    RouteOptions options = const RouteOptions(),
    bool alternatives = true,
  }) async {
    final body = <String, dynamic>{
      'locations': [
        {'lat': origin.lat, 'lon': origin.lng},
        {'lat': destination.lat, 'lon': destination.lng},
      ],
      'costing': profile.valhalla,
      'costing_options': {profile.valhalla: _costingOptions(profile, options)},
      'directions_options': {
        'units': 'kilometers',
        'language': options.language,
      },
      if (alternatives) 'alternates': 2,
    };

    Response<dynamic> resp;
    try {
      resp = await _dio.post<dynamic>(
        '${AppConfig.valhallaBaseUrl}/route',
        data: body,
      );
    } on DioException catch (e) {
      throw RouteException(_mapDioError(e, options.language));
    }

    try {
      final data = resp.data is Map
          ? resp.data as Map<String, dynamic>
          : Map<String, dynamic>.from(resp.data as Map);
      final trip = data['trip'] as Map<String, dynamic>?;
      if (trip == null) {
        throw RouteException(
          _localized(
            options.language,
            vi: 'Không tìm thấy tuyến đường.',
            en: 'No route found.',
          ),
        );
      }

      final routes = <RouteModel>[];
      routes.add(_parseTrip(trip, profile, options.language));

      final alternates = trip['alternates'] as List<dynamic>?;
      if (alternates != null) {
        for (final alt in alternates) {
          final altMap = alt as Map<String, dynamic>;
          final altTrip = altMap['trip'] as Map<String, dynamic>? ?? altMap;
          routes.add(_parseTrip(altTrip, profile, options.language));
        }
      }
      return routes;
    } on RouteException {
      rethrow;
    } catch (e) {
      throw RouteException(
        _localized(
          options.language,
          vi: 'Lỗi phân tích dữ liệu tuyến: $e',
          en: 'Could not parse route data: $e',
        ),
      );
    }
  }

  Map<String, dynamic> _costingOptions(
    TravelProfile profile,
    RouteOptions options,
  ) {
    final avoidHighways = options.avoidHighways || profile.avoidHighwaysDefault;
    return <String, dynamic>{
      // Valhalla: 0.0 = tránh hẳn, 1.0 = ưu tiên dùng.
      'use_tolls': options.avoidTolls ? 0.0 : 0.5,
      'use_highways': avoidHighways ? 0.0 : 1.0,
    };
  }

  RouteModel _parseTrip(
    Map<String, dynamic> trip,
    TravelProfile profile,
    String language,
  ) {
    final legsJson = (trip['legs'] as List<dynamic>? ?? const []);
    final geometry = <GeoPoint>[];
    final legs = <RouteLeg>[];
    final warnings = <String>[];
    bool hasMotorwayWarn = false;

    for (final legJ in legsJson) {
      final leg = legJ as Map<String, dynamic>;
      final shape = leg['shape'] as String? ?? '';
      // Offset để giữ index liên tục khi nối nhiều leg.
      final baseIdx = geometry.length;
      final legPts = decodePolyline6(shape);
      geometry.addAll(legPts);

      final maneuversJson = (leg['maneuvers'] as List<dynamic>? ?? const []);
      final maneuvers = <Maneuver>[];
      for (final mJ in maneuversJson) {
        final m = mJ as Map<String, dynamic>;
        final beginIdx =
            baseIdx + ((m['begin_shape_index'] as num?)?.toInt() ?? 0);
        final loc = (beginIdx >= 0 && beginIdx < geometry.length)
            ? geometry[beginIdx]
            : (geometry.isNotEmpty ? geometry.first : const GeoPoint(0, 0));
        final streetNames = m['street_names'] as List<dynamic>?;
        final streetName = (streetNames != null && streetNames.isNotEmpty)
            ? streetNames.first.toString()
            : '';
        final instruction = m['instruction']?.toString() ?? '';
        final typeInt = (m['type'] as num?)?.toInt() ?? 0;
        final roundExit = (m['roundabout_exit_count'] as num?)?.toInt();

        if (profile == TravelProfile.motorScooter &&
            _mentionsMotorway(instruction, streetName)) {
          hasMotorwayWarn = true;
        }

        maneuvers.add(
          Maneuver(
            type: ManeuverType.fromValhalla(typeInt),
            instructionText: instruction,
            streetName: streetName,
            location: loc,
            distanceToNextM: ((m['length'] as num?)?.toDouble() ?? 0) * 1000,
            durationToNextS: (m['time'] as num?)?.toDouble() ?? 0,
            beginShapeIndex: beginIdx,
            exitNumber: roundExit,
          ),
        );
      }

      legs.add(
        RouteLeg(
          maneuvers: maneuvers,
          distanceM:
              ((leg['summary']?['length'] as num?)?.toDouble() ?? 0) * 1000,
          durationS: (leg['summary']?['time'] as num?)?.toDouble() ?? 0,
        ),
      );
    }

    final summaryJson = trip['summary'] as Map<String, dynamic>?;
    final distanceM =
        ((summaryJson?['length'] as num?)?.toDouble() ?? 0) * 1000;
    final durationS = (summaryJson?['time'] as num?)?.toDouble() ?? 0;

    if (hasMotorwayWarn) {
      warnings.add(
        _localized(
          language,
          vi: '1 đoạn không phù hợp xe máy',
          en: '1 segment is not suitable for scooters',
        ),
      );
    }

    return RouteModel(
      geometry: geometry,
      distanceM: distanceM,
      durationS: durationS,
      legs: legs,
      profile: profile,
      warnings: warnings,
      summary: _buildSummary(legs),
    );
  }

  String _buildSummary(List<RouteLeg> legs) {
    // Lấy tên phố đầu tiên không rỗng trong các maneuver làm tóm tắt.
    for (final leg in legs) {
      for (final m in leg.maneuvers) {
        if (m.streetName.isNotEmpty) return m.streetName;
      }
    }
    return '';
  }

  bool _mentionsMotorway(String instruction, String street) {
    final s = '$instruction $street'.toLowerCase();
    return s.contains('motorway') ||
        s.contains('cao tốc') ||
        s.contains('cao toc');
  }

  String _mapDioError(DioException e, String language) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout) {
      return _localized(
        language,
        vi: 'Hết thời gian kết nối máy chủ định tuyến.',
        en: 'Routing server connection timed out.',
      );
    }
    if (e.response != null) {
      return _localized(
        language,
        vi: 'Máy chủ định tuyến lỗi (HTTP ${e.response?.statusCode}).',
        en: 'Routing server error (HTTP ${e.response?.statusCode}).',
      );
    }
    return _localized(
      language,
      vi: 'Không thể kết nối máy chủ định tuyến.',
      en: 'Could not connect to routing server.',
    );
  }

  String _localized(
    String language, {
    required String vi,
    required String en,
  }) => language.toLowerCase().startsWith('en') ? en : vi;
}
