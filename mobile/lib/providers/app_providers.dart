import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ble/flutter_blue_transport.dart';
import '../ble/i_ble_transport.dart';
import '../core/event_bus.dart';
import '../navigation/i_location_service.dart';
import '../navigation/location_service.dart';
import '../routing/i_route_service.dart';
import '../routing/valhalla_route_service.dart';
import '../search/geocoding_service.dart';
import '../search/i_geocoding_service.dart';
import '../traffic/i_sign_service.dart';
import '../traffic/overpass_road_service.dart';
import '../traffic/overpass_sign_service.dart';

/// Override trong main() sau khi `SharedPreferences.getInstance()`.
final sharedPrefsProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('override in main()'),
);

final dioProvider = Provider<Dio>((ref) {
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 20),
  ));
  return dio;
});

/// Event bus dẫn đường (§2.2) — sống suốt vòng đời app.
final navEventBusProvider = Provider<NavEventBus>((ref) {
  final bus = NavEventBus();
  ref.onDispose(bus.dispose);
  return bus;
});

// ── Service providers (impl behind interfaces — swap dễ, §3.2) ────────

final routeServiceProvider = Provider<IRouteService>(
  (ref) => ValhallaRouteService(ref.watch(dioProvider)),
);

final geocodingServiceProvider = Provider<IGeocodingService>(
  (ref) => GeocodingService(ref.watch(dioProvider)),
);

final signServiceProvider = Provider<ISignService>(
  (ref) => OverpassSignService(ref.watch(dioProvider)),
);

final locationServiceProvider = Provider<ILocationService>(
  (ref) => LocationService(),
);

final overpassRoadServiceProvider = Provider<OverpassRoadService>(
  (ref) => OverpassRoadService(ref.watch(dioProvider)),
);

final bleTransportProvider = Provider<IBleTransport>((ref) {
  final t = FlutterBlueTransport();
  ref.onDispose(t.dispose);
  return t;
});
