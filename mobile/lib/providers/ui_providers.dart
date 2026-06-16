import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_settings.dart';
import '../models/geo_point.dart';
import '../models/place.dart';
import '../models/travel_profile.dart';
import '../navigation/i_location_service.dart';
import 'app_providers.dart';

// ── Quyền vị trí — gate full-screen khi chưa sẵn sàng (§11.9) ────────
class LocationPermissionController
    extends AsyncNotifier<LocationPermissionStatus> {
  @override
  Future<LocationPermissionStatus> build() =>
      ref.read(locationServiceProvider).checkStatus();

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = AsyncData(await ref.read(locationServiceProvider).checkStatus());
  }

  /// Xin quyền hệ thống rồi tự refresh trạng thái.
  Future<void> request() async {
    await ref.read(locationServiceProvider).ensureReady();
    await refresh();
  }
}

final locationPermissionProvider =
    AsyncNotifierProvider<LocationPermissionController, LocationPermissionStatus>(
  LocationPermissionController.new,
);

// ── Profile (ô tô / xe máy / xe đạp) — sticky ở S1 ───────────────────
class ProfileNotifier extends Notifier<TravelProfile> {
  static const _key = 'travel_profile';
  @override
  TravelProfile build() {
    final saved = ref.read(sharedPrefsProvider).getString(_key);
    return TravelProfile.values.firstWhere(
      (p) => p.name == saved,
      orElse: () => TravelProfile.auto,
    );
  }

  void set(TravelProfile p) {
    state = p;
    ref.read(sharedPrefsProvider).setString(_key, p.name);
  }
}

final profileProvider = NotifierProvider<ProfileNotifier, TravelProfile>(
  ProfileNotifier.new,
);

// ── Settings (§11.8) ─────────────────────────────────────────────────
class SettingsNotifier extends Notifier<AppSettings> {
  static const _key = 'app_settings';

  @override
  AppSettings build() {
    final raw = ref.read(sharedPrefsProvider).getString(_key);
    if (raw == null) return const AppSettings();
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return AppSettings(
        themeMode: AppThemeMode.values[m['themeMode'] ?? 2],
        language: _languageFromJson(m['language']),
        bannerTextSize: BannerTextSize.values[m['bannerTextSize'] ?? 0],
        overspeedThreshold: OverspeedThreshold.values[m['overspeed'] ?? 1],
        avoidHighwaysForScooter: m['avoidHwScooter'] ?? true,
        ttsRate: (m['ttsRate'] ?? 0.5).toDouble(),
        ttsEnabled: m['ttsEnabled'] ?? true,
        autoReconnectBle: m['autoReconnect'] ?? true,
        vibrateOnBleLost: m['vibrateBleLost'] ?? true,
        sendFullContent: m['sendFull'] ?? true,
        forceStripDiacritics: m['forceStrip'] ?? false,
      );
    } catch (_) {
      return const AppSettings();
    }
  }

  void update(AppSettings s) {
    state = s;
    final m = {
      'themeMode': s.themeMode.index,
      'language': s.language.name,
      'bannerTextSize': s.bannerTextSize.index,
      'overspeed': s.overspeedThreshold.index,
      'avoidHwScooter': s.avoidHighwaysForScooter,
      'ttsRate': s.ttsRate,
      'ttsEnabled': s.ttsEnabled,
      'autoReconnect': s.autoReconnectBle,
      'vibrateBleLost': s.vibrateOnBleLost,
      'sendFull': s.sendFullContent,
      'forceStrip': s.forceStripDiacritics,
    };
    ref.read(sharedPrefsProvider).setString(_key, jsonEncode(m));
  }

  AppLanguage _languageFromJson(dynamic value) {
    if (value is String) {
      return AppLanguage.values.firstWhere(
        (language) => language.name == value,
        orElse: () => AppLanguage.vi,
      );
    }
    if (value is int && value >= 0 && value < AppLanguage.values.length) {
      return AppLanguage.values[value];
    }
    return AppLanguage.vi;
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

// ── Places: Nhà / Công ty / favorites / lịch sử (§11.4) ──────────────
@immutable
class PlacesState {
  static const _unset = Object();
  final Place? home;
  final Place? work;
  final List<Place> favorites;
  final List<Place> history;
  const PlacesState({
    this.home,
    this.work,
    this.favorites = const [],
    this.history = const [],
  });

  PlacesState copyWith({
    Object? home = _unset,
    Object? work = _unset,
    List<Place>? favorites,
    List<Place>? history,
  }) {
    return PlacesState(
      home: home == _unset ? this.home : home as Place?,
      work: work == _unset ? this.work : work as Place?,
      favorites: favorites ?? this.favorites,
      history: history ?? this.history,
    );
  }
}

class PlacesNotifier extends Notifier<PlacesState> {
  static const _key = 'places_state';

  @override
  PlacesState build() {
    final raw = ref.read(sharedPrefsProvider).getString(_key);
    if (raw == null) return const PlacesState();
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return PlacesState(
        home: _fromJson(m['home']),
        work: _fromJson(m['work']),
        favorites: _listFromJson(m['favorites']),
        history: _listFromJson(m['history']),
      );
    } catch (_) {
      return const PlacesState();
    }
  }

  void addHistory(Place p) {
    final list = [
      p,
      ...state.history.where((e) => e.id != p.id),
    ].take(20).toList();
    _commit(state.copyWith(history: list));
  }

  void removeHistory(String id) => _commit(
    state.copyWith(history: state.history.where((e) => e.id != id).toList()),
  );

  void setHome(Place? p) => _commit(state.copyWith(home: p));
  void setWork(Place? p) => _commit(state.copyWith(work: p));

  void toggleFavorite(Place p) {
    final exists = state.favorites.any((e) => e.id == p.id);
    final list = exists
        ? state.favorites.where((e) => e.id != p.id).toList()
        : [...state.favorites, p];
    _commit(state.copyWith(favorites: list));
  }

  void _commit(PlacesState s) {
    state = s;
    final m = {
      'home': _toJson(s.home),
      'work': _toJson(s.work),
      'favorites': s.favorites.map(_toJson).toList(),
      'history': s.history.map(_toJson).toList(),
    };
    ref.read(sharedPrefsProvider).setString(_key, jsonEncode(m));
  }

  static Map<String, dynamic>? _toJson(Place? p) => p == null
      ? null
      : {
          'id': p.id,
          'name': p.name,
          'address': p.address,
          'lat': p.location.lat,
          'lng': p.location.lng,
          'kind': p.kind.index,
        };

  static Place? _fromJson(dynamic j) {
    if (j == null) return null;
    final m = j as Map<String, dynamic>;
    return Place(
      id: m['id'],
      name: m['name'],
      address: m['address'] ?? '',
      location: GeoPoint(
        (m['lat'] as num).toDouble(),
        (m['lng'] as num).toDouble(),
      ),
      kind: PlaceKind.values[m['kind'] ?? 0],
    );
  }

  static List<Place> _listFromJson(dynamic j) =>
      (j as List? ?? []).map((e) => _fromJson(e)!).toList();
}

final placesProvider = NotifierProvider<PlacesNotifier, PlacesState>(
  PlacesNotifier.new,
);

// ── Search (geocoding, debounce ở UI) ────────────────────────────────
class SearchController extends Notifier<AsyncValue<List<Place>>> {
  int _requestId = 0;

  @override
  AsyncValue<List<Place>> build() => const AsyncData([]);

  Future<void> search(String query, {GeoPoint? near}) async {
    final requestId = ++_requestId;
    final q = query.trim();
    if (q.length < 2) {
      state = const AsyncData([]);
      return;
    }
    state = const AsyncLoading();
    try {
      final results = await ref
          .read(geocodingServiceProvider)
          .search(q, near: near);
      if (requestId == _requestId) {
        state = AsyncData(results);
      }
    } catch (e, st) {
      if (requestId == _requestId) {
        state = AsyncError(e, st);
      }
    }
  }

  void clear() {
    _requestId++;
    state = const AsyncData([]);
  }
}

final searchProvider =
    NotifierProvider<SearchController, AsyncValue<List<Place>>>(
      SearchController.new,
    );
