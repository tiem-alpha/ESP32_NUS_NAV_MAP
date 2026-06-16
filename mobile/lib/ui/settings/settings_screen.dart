import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/app_localizations.dart';
import '../../models/app_settings.dart';
import '../../models/place.dart';
import '../../navigation/nav_voice.dart';
import '../../providers/app_providers.dart';
import '../../providers/ui_providers.dart';
import '../ble_manager/ble_device_manager_screen.dart';
import '../hud_sim/hud_sim_screen.dart';
import '../widgets/set_location_sheet.dart';

/// S6 — Settings (§11.8). Nhóm: Dẫn đường, Hiển thị, Thiết bị HUD, Bản đồ & dữ
/// liệu, Địa điểm. Bind vào settingsProvider / placesProvider.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  Future<void> _showSetLocationSheet({required bool isHome}) async {
    final l10n = context.l10n;
    final title = isHome ? l10n.setHome : l10n.setWork;
    final kind = isHome ? PlaceKind.home : PlaceKind.work;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SetLocationSheet(
        title: title,
        kind: kind,
        geocodingService: ref.read(geocodingServiceProvider),
        currentLocation: null,
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

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final places = ref.watch(placesProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final l10n = context.l10n;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListView(
        children: [
          _section(l10n.navigationSection),
          SwitchListTile(
            title: Text(l10n.ttsVoiceTitle),
            subtitle: Text(l10n.ttsVoiceSubtitle),
            value: s.ttsEnabled,
            onChanged: (v) {
              notifier.update(s.copyWith(ttsEnabled: v));
              if (v) {
                final sample = l10n.ttsEnabledSample;
                Future.delayed(const Duration(milliseconds: 100), () {
                  ref.read(navVoiceProvider).speak(sample);
                });
              }
            },
          ),
          ListTile(
            title: Text(l10n.ttsRateTitle),
            subtitle: Slider(
              value: s.ttsRate,
              min: 0,
              max: 1,
              divisions: 10,
              label: '${(s.ttsRate * 100).round()}%',
              onChanged: s.ttsEnabled
                  ? (v) => notifier.update(s.copyWith(ttsRate: v))
                  : null,
            ),
          ),
          ListTile(
            title: Text(l10n.overspeedTitle),
            trailing: DropdownButton<OverspeedThreshold>(
              value: s.overspeedThreshold,
              onChanged: (v) => v == null
                  ? null
                  : notifier.update(s.copyWith(overspeedThreshold: v)),
              items: [
                for (final t in OverspeedThreshold.values)
                  DropdownMenuItem(value: t, child: Text(t.label)),
              ],
            ),
          ),
          SwitchListTile(
            title: Text(l10n.avoidHighwaysScooterTitle),
            value: s.avoidHighwaysForScooter,
            onChanged: (v) =>
                notifier.update(s.copyWith(avoidHighwaysForScooter: v)),
          ),

          _section(l10n.displaySection),
          ListTile(
            title: Text(l10n.languageTitle),
            trailing: DropdownButton<AppLanguage>(
              value: s.language,
              onChanged: (v) =>
                  v == null ? null : notifier.update(s.copyWith(language: v)),
              items: [
                for (final language in AppLanguage.values)
                  DropdownMenuItem(
                    value: language,
                    child: Text(l10n.languageName(language)),
                  ),
              ],
            ),
          ),
          ListTile(
            title: Text(l10n.themeTitle),
            trailing: DropdownButton<AppThemeMode>(
              value: s.themeMode,
              onChanged: (v) =>
                  v == null ? null : notifier.update(s.copyWith(themeMode: v)),
              items: [
                DropdownMenuItem(
                  value: AppThemeMode.light,
                  child: Text(l10n.themeLight),
                ),
                DropdownMenuItem(
                  value: AppThemeMode.dark,
                  child: Text(l10n.themeDark),
                ),
                DropdownMenuItem(
                  value: AppThemeMode.auto,
                  child: Text(l10n.themeAuto),
                ),
              ],
            ),
          ),
          ListTile(
            title: Text(l10n.bannerTextSizeTitle),
            trailing: DropdownButton<BannerTextSize>(
              value: s.bannerTextSize,
              onChanged: (v) => v == null
                  ? null
                  : notifier.update(s.copyWith(bannerTextSize: v)),
              items: [
                DropdownMenuItem(
                  value: BannerTextSize.large,
                  child: Text(l10n.bannerLarge),
                ),
                DropdownMenuItem(
                  value: BannerTextSize.xlarge,
                  child: Text(l10n.bannerExtraLarge),
                ),
              ],
            ),
          ),

          _section(l10n.hudDeviceSection),
          ListTile(
            leading: const Icon(Icons.bluetooth),
            title: Text(l10n.manageHudDeviceTitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const BleDeviceManagerScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.preview),
            title: const Text('Mô phỏng HUD'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const HudSimScreen()),
            ),
          ),
          SwitchListTile(
            title: Text(l10n.sendFullContentTitle),
            subtitle: Text(l10n.sendFullContentSubtitle),
            value: s.sendFullContent,
            onChanged: (v) => notifier.update(s.copyWith(sendFullContent: v)),
          ),
          SwitchListTile(
            title: Text(l10n.forceStripDiacriticsTitle),
            subtitle: Text(l10n.forceStripDiacriticsSubtitle),
            value: s.forceStripDiacritics,
            onChanged: (v) =>
                notifier.update(s.copyWith(forceStripDiacritics: v)),
          ),

          _section(l10n.mapDataSection),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: Text(l10n.clearMapCacheTitle),
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.clearMapCacheMessage)),
              );
            },
          ),

          _section(l10n.placesSection),
          ListTile(
            leading: const Icon(Icons.home),
            title: Text(l10n.home),
            subtitle: Text(places.home?.name ?? l10n.notSet),
            onTap: () => _showSetLocationSheet(isHome: true),
            trailing: places.home == null
                ? const Icon(Icons.add)
                : IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () =>
                        ref.read(placesProvider.notifier).setHome(null),
                  ),
          ),
          ListTile(
            leading: const Icon(Icons.work),
            title: Text(l10n.work),
            subtitle: Text(places.work?.name ?? l10n.notSet),
            onTap: () => _showSetLocationSheet(isHome: false),
            trailing: places.work == null
                ? const Icon(Icons.add)
                : IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () =>
                        ref.read(placesProvider.notifier).setWork(null),
                  ),
          ),
          if (places.favorites.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(l10n.favorites),
            ),
            for (final f in places.favorites)
              ListTile(
                leading: const Icon(Icons.star),
                title: Text(f.name),
                subtitle: f.address.isEmpty ? null : Text(f.address),
                trailing: IconButton(
                  icon: const Icon(Icons.star),
                  onPressed: () =>
                      ref.read(placesProvider.notifier).toggleFavorite(f),
                ),
              ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
