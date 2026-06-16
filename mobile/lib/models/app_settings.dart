import 'package:flutter/material.dart';

/// Chế độ theme (§11.6 — Tự động theo giờ mặt trời).
enum AppThemeMode { light, dark, auto }

/// Ngôn ngữ giao diện ứng dụng.
enum AppLanguage {
  vi(Locale('vi')),
  en(Locale('en'));

  final Locale locale;
  const AppLanguage(this.locale);

  String get navigationLanguage => switch (this) {
    AppLanguage.vi => 'vi-VN',
    AppLanguage.en => 'en-US',
  };
}

/// Cỡ chữ banner (§11.8 Hiển thị).
enum BannerTextSize { large, xlarge }

/// Ngưỡng cảnh báo quá tốc độ (§11.8 Dẫn đường).
enum OverspeedThreshold {
  zero(0, '+0 km/h'),
  five(5, '+5 km/h'),
  ten(10, '+10 km/h');

  final int kmh;
  final String label;
  const OverspeedThreshold(this.kmh, this.label);
}

/// Cài đặt người dùng — persist qua shared_preferences (§11.8).
@immutable
class AppSettings {
  final AppThemeMode themeMode;
  final AppLanguage language;
  final BannerTextSize bannerTextSize;
  final OverspeedThreshold overspeedThreshold;
  final bool avoidHighwaysForScooter;
  final double ttsRate; // 0..1
  final bool ttsEnabled;
  final bool autoReconnectBle;
  final bool vibrateOnBleLost;

  /// Nội dung gửi HUD: true = đủ, false = gọn (màn nhỏ chỉ icon + khoảng cách).
  final bool sendFullContent;

  /// Ép bỏ dấu khi gửi (mặc định auto theo capability).
  final bool forceStripDiacritics;

  const AppSettings({
    this.themeMode = AppThemeMode.auto,
    this.language = AppLanguage.vi,
    this.bannerTextSize = BannerTextSize.large,
    this.overspeedThreshold = OverspeedThreshold.five,
    this.avoidHighwaysForScooter = true,
    this.ttsRate = 0.5,
    this.ttsEnabled = true,
    this.autoReconnectBle = true,
    this.vibrateOnBleLost = true,
    this.sendFullContent = true,
    this.forceStripDiacritics = false,
  });

  AppSettings copyWith({
    AppThemeMode? themeMode,
    AppLanguage? language,
    BannerTextSize? bannerTextSize,
    OverspeedThreshold? overspeedThreshold,
    bool? avoidHighwaysForScooter,
    double? ttsRate,
    bool? ttsEnabled,
    bool? autoReconnectBle,
    bool? vibrateOnBleLost,
    bool? sendFullContent,
    bool? forceStripDiacritics,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    language: language ?? this.language,
    bannerTextSize: bannerTextSize ?? this.bannerTextSize,
    overspeedThreshold: overspeedThreshold ?? this.overspeedThreshold,
    avoidHighwaysForScooter:
        avoidHighwaysForScooter ?? this.avoidHighwaysForScooter,
    ttsRate: ttsRate ?? this.ttsRate,
    ttsEnabled: ttsEnabled ?? this.ttsEnabled,
    autoReconnectBle: autoReconnectBle ?? this.autoReconnectBle,
    vibrateOnBleLost: vibrateOnBleLost ?? this.vibrateOnBleLost,
    sendFullContent: sendFullContent ?? this.sendFullContent,
    forceStripDiacritics: forceStripDiacritics ?? this.forceStripDiacritics,
  );
}
