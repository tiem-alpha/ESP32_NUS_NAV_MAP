import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/app_localizations.dart';
import '../../models/geo_point.dart';
import '../../models/place.dart';
import '../../providers/app_providers.dart';
import '../../providers/ui_providers.dart';
import '../widgets/set_location_sheet.dart';

/// S2 — Search full-screen (§11.4).
/// Autofocus + debounce 650ms → searchProvider.search(q, near). Hiển thị
/// shortcut Nhà/Công ty, Lịch sử (swipe-to-delete), rồi kết quả API.
/// Chọn kết quả → Navigator.pop(context, place).
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  static const _searchDebounce = Duration(milliseconds: 650);

  final _controller = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  GeoPoint? _near;
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _focus.requestFocus();
      final fix = await ref.read(locationServiceProvider).current();
      if (mounted) setState(() => _near = fix?.position);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    setState(() => _query = value);
    _debounce?.cancel();
    _debounce = Timer(_searchDebounce, () {
      ref.read(searchProvider.notifier).search(value, near: _near);
    });
  }

  void _select(Place place) {
    ref.read(placesProvider.notifier).addHistory(place);
    ref.read(searchProvider.notifier).clear();
    Navigator.of(context).pop(place);
  }

  Future<void> _showSetLocationSheet({required bool isHome}) async {
    final l10n = context.l10n;
    final title = isHome ? l10n.setHome : l10n.setWork;
    final kind = isHome ? PlaceKind.home : PlaceKind.work;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SetLocationSheet(
        title: title,
        kind: kind,
        geocodingService: ref.read(geocodingServiceProvider),
        currentLocation: _near,
        onSelected: (place) {
          final located = place.copyWith(kind: kind);
          if (isHome) {
            ref.read(placesProvider.notifier).setHome(located);
          } else {
            ref.read(placesProvider.notifier).setWork(located);
          }
          Navigator.pop(ctx);
        },
      ),
    );
  }

  RelativeRect _menuPosition(BuildContext context) {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final size = overlay.size;
    return RelativeRect.fromLTRB(
      size.width / 2,
      size.height / 2,
      size.width / 2,
      size.height / 2,
    );
  }

  @override
  Widget build(BuildContext context) {
    final places = ref.watch(placesProvider);
    final results = ref.watch(searchProvider);
    final showResults = _query.trim().length >= 2;
    final l10n = context.l10n;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          focusNode: _focus,
          onChanged: _onChanged,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: l10n.searchHint,
            border: InputBorder.none,
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _controller.clear();
                      _onChanged('');
                    },
                  ),
          ),
        ),
      ),
      body: showResults ? _buildResults(results) : _buildShortcuts(places),
    );
  }

  Widget _buildShortcuts(PlacesState places) {
    final l10n = context.l10n;
    return ListView(
      children: [
        _shortcutTile(
          icon: Icons.home,
          title: l10n.home,
          place: places.home,
          emptyLabel: l10n.setHome,
          isHome: true,
        ),
        _shortcutTile(
          icon: Icons.work,
          title: l10n.work,
          place: places.work,
          emptyLabel: l10n.setWork,
          isHome: false,
        ),
        if (places.history.isNotEmpty) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(l10n.history),
          ),
          for (final p in places.history)
            Dismissible(
              key: ValueKey('hist_${p.id}'),
              direction: DismissDirection.endToStart,
              background: Container(
                color: Theme.of(context).colorScheme.errorContainer,
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 20),
                child: const Icon(Icons.delete_outline),
              ),
              onDismissed: (_) =>
                  ref.read(placesProvider.notifier).removeHistory(p.id),
              child: _placeTile(p, leading: Icons.history),
            ),
        ],
      ],
    );
  }

  Widget _shortcutTile({
    required IconData icon,
    required String title,
    required Place? place,
    required String emptyLabel,
    required bool isHome,
  }) {
    final l10n = context.l10n;
    return ListTile(
      leading: CircleAvatar(child: Icon(icon)),
      title: Text(title, style: Theme.of(context).textTheme.titleMedium),
      subtitle: place == null
          ? Text(emptyLabel)
          : Text(place.address.isEmpty ? place.name : place.address),
      onTap: place == null
          ? () => _showSetLocationSheet(isHome: isHome)
          : () => _select(place),
      onLongPress: place == null
          ? null
          : () async {
              final action = await showMenu<String>(
                context: context,
                position: _menuPosition(context),
                items: [
                  PopupMenuItem(value: 'update', child: Text(l10n.update)),
                  PopupMenuItem(value: 'clear', child: Text(l10n.clear)),
                ],
              );
              if (!mounted) return;
              if (action == 'update') {
                await _showSetLocationSheet(isHome: isHome);
              } else if (action == 'clear') {
                if (isHome) {
                  ref.read(placesProvider.notifier).setHome(null);
                } else {
                  ref.read(placesProvider.notifier).setWork(null);
                }
              }
            },
    );
  }

  Widget _buildResults(AsyncValue<List<Place>> results) {
    final l10n = context.l10n;
    return results.when(
      data: (list) {
        if (list.isEmpty) {
          return _emptyState(icon: Icons.search_off, text: l10n.noPlaceFound);
        }
        return ListView.builder(
          itemCount: list.length,
          itemBuilder: (_, i) =>
              _placeTile(list[i], leading: _kindIcon(list[i].kind)),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _emptyState(
        icon: Icons.error_outline,
        text: l10n.searchError,
        action: TextButton(
          onPressed: () =>
              ref.read(searchProvider.notifier).search(_query, near: _near),
          child: Text(l10n.retry),
        ),
      ),
    );
  }

  Widget _placeTile(Place p, {required IconData leading}) {
    final l10n = context.l10n;
    return ListTile(
      leading: Icon(leading),
      title: Text(
        p.name,
        style: Theme.of(context).textTheme.titleMedium,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: p.address.isEmpty
          ? null
          : Text(
              p.address,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
      onTap: () => _select(p),
      onLongPress: () async {
        final action = await showMenu<String>(
          context: context,
          position: _menuPosition(context),
          items: [
            PopupMenuItem(value: 'home', child: Text(l10n.setAsHome)),
            PopupMenuItem(value: 'work', child: Text(l10n.setAsWork)),
          ],
        );
        if (!mounted) return;
        if (action == 'home') {
          ref
              .read(placesProvider.notifier)
              .setHome(p.copyWith(kind: PlaceKind.home));
        } else if (action == 'work') {
          ref
              .read(placesProvider.notifier)
              .setWork(p.copyWith(kind: PlaceKind.work));
        }
      },
    );
  }

  Widget _emptyState({
    required IconData icon,
    required String text,
    Widget? action,
  }) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: Theme.of(context).disabledColor),
          const SizedBox(height: 12),
          Text(text),
          if (action != null) ...[const SizedBox(height: 8), action],
        ],
      ),
    );
  }

  IconData _kindIcon(PlaceKind kind) {
    switch (kind) {
      case PlaceKind.home:
        return Icons.home;
      case PlaceKind.work:
        return Icons.work;
      case PlaceKind.history:
        return Icons.history;
      case PlaceKind.favorite:
        return Icons.star;
      case PlaceKind.food:
        return Icons.restaurant;
      case PlaceKind.fuel:
        return Icons.local_gas_station;
      case PlaceKind.parking:
        return Icons.local_parking;
      case PlaceKind.generic:
        return Icons.place_outlined;
    }
  }
}
