import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/l10n/app_localizations.dart';
import '../../models/geo_point.dart';
import '../../models/place.dart';
import '../../search/i_geocoding_service.dart';

/// Widget dùng chung để tìm và đặt địa điểm Nhà / Công ty.
/// Được dùng từ SearchScreen và SettingsScreen.
class SetLocationSheet extends StatefulWidget {
  final String title;
  final PlaceKind kind;
  final IGeocodingService geocodingService;
  final GeoPoint? currentLocation;
  final void Function(Place) onSelected;

  const SetLocationSheet({
    super.key,
    required this.title,
    required this.kind,
    required this.geocodingService,
    required this.currentLocation,
    required this.onSelected,
  });

  @override
  State<SetLocationSheet> createState() => _SetLocationSheetState();
}

class _SetLocationSheetState extends State<SetLocationSheet> {
  static const _searchDebounce = Duration(milliseconds: 650);

  final _controller = TextEditingController();
  Timer? _debounce;
  List<Place> _results = [];
  bool _loading = false;
  bool _hasError = false;
  int _requestId = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    final requestId = ++_requestId;
    final q = value.trim();
    if (q.length < 2) {
      setState(() {
        _results = [];
        _loading = false;
        _hasError = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _hasError = false;
    });
    _debounce = Timer(_searchDebounce, () async {
      try {
        final results = await widget.geocodingService.search(
          q,
          near: widget.currentLocation,
        );
        if (mounted && requestId == _requestId) {
          setState(() {
            _results = results;
            _loading = false;
          });
        }
      } catch (_) {
        if (mounted && requestId == _requestId) {
          setState(() {
            _hasError = true;
            _loading = false;
          });
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final l10n = context.l10n;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              widget.title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _controller,
              autofocus: true,
              onChanged: _onChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: l10n.searchHint,
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: _controller.text.isEmpty
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
          const SizedBox(height: 8),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            )
          else if (_hasError)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(l10n.searchError),
            )
          else if (_results.isNotEmpty)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.4,
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _results.length,
                itemBuilder: (_, i) {
                  final place = _results[i];
                  return ListTile(
                    leading: const Icon(Icons.place_outlined),
                    title: Text(
                      place.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: place.address.isEmpty
                        ? null
                        : Text(
                            place.address,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    onTap: () => widget.onSelected(place),
                  );
                },
              ),
            ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
