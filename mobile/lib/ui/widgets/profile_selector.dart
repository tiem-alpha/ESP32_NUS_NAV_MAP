import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/app_localizations.dart';
import '../../models/travel_profile.dart';
import '../../providers/ui_providers.dart';

/// SegmentedButton chọn profile (🚗 Ô tô / 🛵 Xe máy / 🚲 Xe đạp).
/// Đọc/ghi [profileProvider]; nếu truyền [onChanged] thì gọi thêm callback
/// (vd S1 để re-request route khi sheet đang mở). (§11.3)
class ProfileSelector extends ConsumerWidget {
  final ValueChanged<TravelProfile>? onChanged;
  final bool showLabels;

  const ProfileSelector({super.key, this.onChanged, this.showLabels = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider);
    final l10n = context.l10n;

    return SegmentedButton<TravelProfile>(
      showSelectedIcon: false,
      segments: [
        for (final p in TravelProfile.values)
          ButtonSegment<TravelProfile>(
            value: p,
            label: Text(
              showLabels ? '${p.emoji} ${l10n.profileLabel(p)}' : p.emoji,
            ),
          ),
      ],
      selected: {profile},
      onSelectionChanged: (sel) {
        final p = sel.first;
        ref.read(profileProvider.notifier).set(p);
        onChanged?.call(p);
      },
    );
  }
}
