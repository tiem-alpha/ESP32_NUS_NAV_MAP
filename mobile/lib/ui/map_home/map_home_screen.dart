import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../models/geo_point.dart';
import '../../models/nav_state.dart';
import '../../models/place.dart';
import '../../providers/app_providers.dart';
import '../../navigation/nav_controller.dart';
import '../../providers/nav_providers.dart';
import '../navigation/navigation_screen.dart';
import '../route_preview/route_preview_sheet.dart';
import '../search/search_screen.dart';
import '../settings/settings_screen.dart';
import '../map/map_view.dart';
import '../widgets/ble_chip.dart';
import '../widgets/bluetooth_off_banner.dart';
import '../widgets/profile_selector.dart';

/// S1 — Map Home (§11.3). Map nền + search bar nổi + BLE chip + recenter FAB +
/// ProfileSelector sticky. Long-press → reverse geocode → mini sheet → S3.
/// routePreviewProvider có data → RoutePreviewSheet. navController active →
/// push NavigationScreen.
class MapHomeScreen extends ConsumerStatefulWidget {
  const MapHomeScreen({super.key});

  @override
  ConsumerState<MapHomeScreen> createState() => _MapHomeScreenState();
}

class _MapHomeScreenState extends ConsumerState<MapHomeScreen> {
  final GlobalKey<MapViewState> _mapKey = GlobalKey<MapViewState>();
  GeoPoint? _userLocation;
  double _cameraBearing = 0;
  bool _navPushed = false;

  @override
  void initState() {
    super.initState();
    _loadLocation();
  }

  Future<void> _loadLocation() async {
    final fix = await ref.read(locationServiceProvider).current();
    if (mounted && fix != null) {
      setState(() => _userLocation = fix.position);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = ref.watch(routePreviewProvider);
    final hasPreview =
        preview.value != null || preview.isLoading || preview.hasError;
    final selectedRoutes = preview.value?.routes ?? const [];
    final selectedIndex = preview.value?.selectedIndex ?? 0;
    final destination = preview.value?.destination.location;

    // Khi navigation active → push S4 (một lần).
    ref.listen<NavSnapshot>(navControllerProvider, (prev, next) {
      if (next.isActive && !_navPushed) {
        _navPushed = true;
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const NavigationScreen()))
            .then((_) => _navPushed = false);
      }
    });

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: MapView(
              key: _mapKey,
              routes: selectedRoutes,
              selectedIndex: selectedIndex,
              userLocation: _userLocation,
              follow: false,
              destination: destination,
              onLongPress: _onMapLongPress,
              onCameraBearingChanged: (b) {
                if ((b - _cameraBearing).abs() > 1) {
                  setState(() => _cameraBearing = b);
                }
              },
            ),
          ),

          // Banner Bluetooth tắt (§11.9) + search bar + BLE chip/la bàn.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Column(
                children: [
                  const BluetoothOffBanner(),
                  _searchBar(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const BleChip(),
                        // Nút la bàn khi map xoay.
                        if (_cameraBearing.abs() > 1)
                          FloatingActionButton.small(
                            heroTag: 'compass',
                            onPressed: () {
                              _mapKey.currentState?.resetNorth();
                              setState(() => _cameraBearing = 0);
                            },
                            child: Transform.rotate(
                              angle: -_cameraBearing * 3.1415926 / 180,
                              child: const Icon(Icons.navigation),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Recenter FAB bottom-right.
          Positioned(
            right: 12,
            bottom: hasPreview ? 0 : 96,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: FloatingActionButton(
                  heroTag: 'recenter',
                  onPressed: _recenter,
                  child: const Icon(Icons.my_location),
                ),
              ),
            ),
          ),

          // ProfileSelector sticky bottom (ẩn khi đang preview).
          if (!hasPreview)
            Positioned(
              left: 12,
              right: 12,
              bottom: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Center(
                    child: ProfileSelector(
                      onChanged: (p) {
                        // Nếu sheet preview đang mở → re-request.
                        if (ref.read(routePreviewProvider).value != null) {
                          ref.read(routePreviewProvider.notifier).setProfile(p);
                        }
                      },
                    ),
                  ),
                ),
              ),
            ),

          // S3 Route Preview sheet trên map.
          if (hasPreview)
            DraggableScrollableSheet(
              initialChildSize: 0.42,
              minChildSize: 0.25,
              maxChildSize: 0.9,
              snap: true,
              snapSizes: const [0.25, 0.5, 0.9],
              builder: (context, scrollController) {
                return Material(
                  elevation: 8,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(28),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    children: [
                      RoutePreviewSheet(scrollController: scrollController),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () =>
                              ref.read(routePreviewProvider.notifier).clear(),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _searchBar() {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Material(
        elevation: 2,
        borderRadius: BorderRadius.circular(28),
        color: context.scheme.surface,
        child: InkWell(
          borderRadius: BorderRadius.circular(28),
          onTap: _openSearch,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(Icons.search, color: context.scheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l10n.searchHint,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: context.scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.settings),
                  tooltip: l10n.settingsTitle,
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openSearch() async {
    final place = await Navigator.of(
      context,
    ).push<Place>(MaterialPageRoute(builder: (_) => const SearchScreen()));
    if (place == null || !mounted) return;
    _mapKey.currentState?.flyTo(place.location);
    ref
        .read(routePreviewProvider.notifier)
        .request(place, origin: _userLocation);
  }

  Future<void> _onMapLongPress(GeoPoint point) async {
    final selectedLocation = context.l10n.selectedLocation;
    Place? place;
    try {
      place = await ref.read(geocodingServiceProvider).reverse(point);
    } catch (_) {
      place = null;
    }
    place ??= Place(
      id: 'pin_${point.lat}_${point.lng}',
      name: selectedLocation,
      address:
          '${point.lat.toStringAsFixed(5)}, ${point.lng.toStringAsFixed(5)}',
      location: point,
    );
    if (!mounted) return;
    _showDropPinSheet(place);
  }

  void _showDropPinSheet(Place place) {
    final l10n = context.l10n;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(place.name, style: Theme.of(context).textTheme.titleMedium),
              if (place.address.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    place.address,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: FilledButton.icon(
                  icon: const Icon(Icons.directions),
                  label: Text(l10n.directionsToHere),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _mapKey.currentState?.flyTo(place.location);
                    ref
                        .read(routePreviewProvider.notifier)
                        .request(place, origin: _userLocation);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _recenter() async {
    final fix = await ref.read(locationServiceProvider).current();
    if (fix == null || !mounted) return;
    setState(() => _userLocation = fix.position);
    _mapKey.currentState?.flyTo(fix.position, zoom: 16);
  }
}
