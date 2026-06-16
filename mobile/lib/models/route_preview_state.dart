import 'place.dart';
import 'route_model.dart';
import 'travel_profile.dart';

/// Trạng thái S3 Route Preview: danh sách tuyến (chính + alternatives) và
/// tuyến đang chọn. UI vẽ route đậm/mờ và sheet từ đây.
class RoutePreviewState {
  final Place destination;
  final TravelProfile profile;
  final List<RouteModel> routes;
  final int selectedIndex;
  final bool avoidTolls;
  final bool avoidHighways;

  const RoutePreviewState({
    required this.destination,
    required this.profile,
    required this.routes,
    this.selectedIndex = 0,
    this.avoidTolls = false,
    this.avoidHighways = false,
  });

  RouteModel get selected => routes[selectedIndex];

  RoutePreviewState copyWith({
    List<RouteModel>? routes,
    int? selectedIndex,
    TravelProfile? profile,
    bool? avoidTolls,
    bool? avoidHighways,
  }) =>
      RoutePreviewState(
        destination: destination,
        profile: profile ?? this.profile,
        routes: routes ?? this.routes,
        selectedIndex: selectedIndex ?? this.selectedIndex,
        avoidTolls: avoidTolls ?? this.avoidTolls,
        avoidHighways: avoidHighways ?? this.avoidHighways,
      );
}
