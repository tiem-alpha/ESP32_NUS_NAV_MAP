import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/geo_point.dart';
import '../models/place.dart';
import '../models/route_preview_state.dart';
import '../models/travel_profile.dart';
import '../navigation/nav_controller.dart';
import '../routing/i_route_service.dart';
import 'app_providers.dart';
import 'ui_providers.dart';

/// Controller S3 Route Preview: tính tuyến (chính + alternatives), đổi tuyến,
/// toggle tránh phí/cao tốc, đổi profile (re-request).
class RoutePreviewController extends Notifier<AsyncValue<RoutePreviewState?>> {
  int _requestId = 0;

  @override
  AsyncValue<RoutePreviewState?> build() => const AsyncData(null);

  /// Bắt đầu preview tới [destination] (gọi khi chọn kết quả search / drop pin).
  Future<void> request(Place destination, {GeoPoint? origin}) async {
    final profile = ref.read(profileProvider);
    final settings = ref.read(settingsProvider);
    final avoidHw =
        profile == TravelProfile.motorScooter &&
        settings.avoidHighwaysForScooter;
    await _compute(
      destination: destination,
      profile: profile,
      origin: origin,
      avoidTolls: false,
      avoidHighways: avoidHw,
    );
  }

  Future<void> setProfile(TravelProfile p) async {
    final cur = state.value;
    if (cur == null) return;
    ref.read(profileProvider.notifier).set(p);
    await _compute(
      destination: cur.destination,
      profile: p,
      avoidTolls: cur.avoidTolls,
      avoidHighways: cur.avoidHighways,
    );
  }

  Future<void> toggleTolls() async {
    final cur = state.value;
    if (cur == null) return;
    await _compute(
      destination: cur.destination,
      profile: cur.profile,
      avoidTolls: !cur.avoidTolls,
      avoidHighways: cur.avoidHighways,
    );
  }

  Future<void> toggleHighways() async {
    final cur = state.value;
    if (cur == null) return;
    await _compute(
      destination: cur.destination,
      profile: cur.profile,
      avoidTolls: cur.avoidTolls,
      avoidHighways: !cur.avoidHighways,
    );
  }

  void selectRoute(int index) {
    final cur = state.value;
    if (cur == null || index < 0 || index >= cur.routes.length) return;
    state = AsyncData(cur.copyWith(selectedIndex: index));
  }

  /// Nút "BẮT ĐẦU" ở S3 → khởi động NavController với tuyến đang chọn.
  Future<void> begin() async {
    final cur = state.value;
    if (cur == null) return;
    ref.read(placesProvider.notifier).addHistory(cur.destination);
    await ref
        .read(navControllerProvider.notifier)
        .startNavigation(
          route: cur.selected,
          destination: cur.destination,
          options: RouteOptions(
            avoidTolls: cur.avoidTolls,
            avoidHighways: cur.avoidHighways,
            language: ref.read(settingsProvider).language.navigationLanguage,
          ),
        );
  }

  void clear() {
    _requestId++;
    state = const AsyncData(null);
  }

  Future<void> _compute({
    required Place destination,
    required TravelProfile profile,
    GeoPoint? origin,
    required bool avoidTolls,
    required bool avoidHighways,
  }) async {
    final requestId = ++_requestId;
    state = const AsyncLoading();
    try {
      final language = ref.read(settingsProvider).language.navigationLanguage;
      final from = origin ?? await _currentOrigin();
      if (!_isCurrent(requestId)) return;
      if (from == null) {
        state = AsyncError(
          _localized(
            language,
            vi: 'Không lấy được vị trí hiện tại',
            en: 'Could not get current location',
          ),
          StackTrace.current,
        );
        return;
      }
      final options = RouteOptions(
        avoidTolls: avoidTolls,
        avoidHighways: avoidHighways,
        language: language,
      );
      final routes = await ref
          .read(routeServiceProvider)
          .route(
            origin: from,
            destination: destination.location,
            profile: profile,
            options: options,
            alternatives: false,
          );
      if (!_isCurrent(requestId)) return;
      if (routes.isEmpty) {
        state = AsyncError(
          _localized(
            language,
            vi: 'Không tìm được tuyến',
            en: 'No route found',
          ),
          StackTrace.current,
        );
        return;
      }
      state = AsyncData(
        RoutePreviewState(
          destination: destination,
          profile: profile,
          routes: routes,
          avoidTolls: avoidTolls,
          avoidHighways: avoidHighways,
        ),
      );
      unawaited(
        _loadAlternatives(
          requestId: requestId,
          origin: from,
          destination: destination,
          profile: profile,
          options: options,
          avoidTolls: avoidTolls,
          avoidHighways: avoidHighways,
        ),
      );
    } catch (e, st) {
      if (_isCurrent(requestId)) state = AsyncError(e, st);
    }
  }

  Future<GeoPoint?> _currentOrigin() async {
    final fix = await ref.read(locationServiceProvider).current();
    return fix?.position;
  }

  Future<void> _loadAlternatives({
    required int requestId,
    required GeoPoint origin,
    required Place destination,
    required TravelProfile profile,
    required RouteOptions options,
    required bool avoidTolls,
    required bool avoidHighways,
  }) async {
    try {
      final routes = await ref
          .read(routeServiceProvider)
          .route(
            origin: origin,
            destination: destination.location,
            profile: profile,
            options: options,
            alternatives: true,
          );
      if (!_isCurrent(requestId) || routes.isEmpty) return;
      state = AsyncData(
        RoutePreviewState(
          destination: destination,
          profile: profile,
          routes: routes,
          avoidTolls: avoidTolls,
          avoidHighways: avoidHighways,
        ),
      );
    } catch (_) {
      // Tuyến phụ là dữ liệu bổ sung; giữ tuyến chính đã hiển thị.
    }
  }

  bool _isCurrent(int requestId) => requestId == _requestId;

  String _localized(
    String language, {
    required String vi,
    required String en,
  }) => language.toLowerCase().startsWith('en') ? en : vi;
}

final routePreviewProvider =
    NotifierProvider<RoutePreviewController, AsyncValue<RoutePreviewState?>>(
      RoutePreviewController.new,
    );
