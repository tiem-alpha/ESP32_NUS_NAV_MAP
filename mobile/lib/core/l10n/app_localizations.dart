import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../models/app_settings.dart';
import '../../models/travel_profile.dart';

class AppLocalizations {
  final Locale locale;

  const AppLocalizations(this.locale);

  static const supportedLocales = [Locale('vi'), Locale('en')];
  static const delegate = _AppLocalizationsDelegate();

  static AppLocalizations of(BuildContext context) =>
      Localizations.of<AppLocalizations>(context, AppLocalizations)!;

  bool get _vi => locale.languageCode == 'vi';

  String _pick(String vi, String en) => _vi ? vi : en;

  String get appTitle => 'NavHUD';
  String get settingsTitle => _pick('Cài đặt', 'Settings');
  String get languageTitle => _pick('Ngôn ngữ', 'Language');
  String languageName(AppLanguage language) => switch (language) {
    AppLanguage.vi => _pick('Tiếng Việt', 'Vietnamese'),
    AppLanguage.en => _pick('Tiếng Anh', 'English'),
  };
  String profileLabel(TravelProfile profile) => switch (profile) {
    TravelProfile.auto => _pick('Ô tô', 'Car'),
    TravelProfile.motorScooter => _pick('Xe máy', 'Scooter'),
    TravelProfile.bicycle => _pick('Xe đạp', 'Bicycle'),
  };

  String get navigationSection => _pick('Dẫn đường', 'Navigation');
  String get ttsVoiceTitle => _pick('Giọng đọc (TTS)', 'Voice guidance (TTS)');
  String get ttsVoiceSubtitle => _pick(
    'Đọc hướng dẫn theo ngôn ngữ ứng dụng',
    'Read guidance in the app language',
  );
  String get ttsEnabledSample =>
      _pick('Xin chào, giọng đọc đã bật', 'Hello, voice guidance is on');
  String get ttsRateTitle => _pick('Tốc độ đọc', 'Speech rate');
  String get overspeedTitle =>
      _pick('Ngưỡng cảnh báo tốc độ', 'Overspeed warning');
  String get avoidHighwaysScooterTitle =>
      _pick('Tự tránh cao tốc cho xe máy', 'Avoid highways for scooter');

  String get displaySection => _pick('Hiển thị', 'Display');
  String get themeTitle => _pick('Giao diện', 'Theme');
  String get themeLight => _pick('Sáng', 'Light');
  String get themeDark => _pick('Tối', 'Dark');
  String get themeAuto => _pick('Tự động', 'Automatic');
  String get bannerTextSizeTitle => _pick('Cỡ chữ banner', 'Banner text size');
  String get bannerLarge => _pick('Lớn', 'Large');
  String get bannerExtraLarge => _pick('Rất lớn', 'Extra large');

  String get hudDeviceSection => _pick('Thiết bị HUD', 'HUD device');
  String get manageHudDeviceTitle =>
      _pick('Quản lý thiết bị HUD', 'Manage HUD device');
  String get sendFullContentTitle =>
      _pick('Gửi nội dung đầy đủ', 'Send full content');
  String get sendFullContentSubtitle => _pick(
    'Tắt = gọn (chỉ icon + khoảng cách)',
    'Off = compact (icon + distance only)',
  );
  String get forceStripDiacriticsTitle =>
      _pick('Ép bỏ dấu khi gửi', 'Force stripping accents');
  String get forceStripDiacriticsSubtitle => _pick(
    'Mặc định tự động theo thiết bị',
    'Default follows device capability',
  );

  String get mapDataSection => _pick('Bản đồ & dữ liệu', 'Map & data');
  String get clearMapCacheTitle => _pick('Xoá cache bản đồ', 'Clear map cache');
  String get clearMapCacheMessage =>
      _pick('Đã xoá cache (placeholder)', 'Map cache cleared (placeholder)');

  String get placesSection => _pick('Địa điểm', 'Places');
  String get home => _pick('Nhà', 'Home');
  String get work => _pick('Công ty', 'Work');
  String get setHome => _pick('Đặt Nhà', 'Set Home');
  String get setWork => _pick('Đặt Công ty', 'Set Work');
  String get notSet => _pick('Chưa đặt', 'Not set');
  String get favorites => _pick('Yêu thích', 'Favorites');
  String get history => _pick('Lịch sử', 'History');
  String get update => _pick('Cập nhật', 'Update');
  String get clear => _pick('Xóa', 'Clear');

  String get searchHint => _pick('Tìm địa điểm…', 'Search places…');
  String get noPlaceFound =>
      _pick('Không tìm thấy địa điểm', 'No places found');
  String get searchError => _pick('Lỗi tìm kiếm', 'Search error');
  String get retry => _pick('Thử lại', 'Retry');
  String get setAsHome => _pick('Đặt làm Nhà', 'Set as Home');
  String get setAsWork => _pick('Đặt làm Công ty', 'Set as Work');
  String get selectedLocation => _pick('Vị trí đã chọn', 'Selected location');
  String get directionsToHere =>
      _pick('Chỉ đường tới đây', 'Directions to here');

  String get routeErrorTitle =>
      _pick('Không tính được tuyến', 'Could not calculate route');
  String via(String summary) => _pick('Qua $summary', 'Via $summary');
  String get avoidTolls => _pick('Tránh phí', 'Avoid tolls');
  String get avoidHighways => _pick('Tránh cao tốc', 'Avoid highways');
  String get start => _pick('BẮT ĐẦU', 'START');
  String get steps => _pick('Các bước', 'Steps');

  String get navigationInProgress =>
      _pick('NavHUD đang dẫn đường', 'NavHUD is navigating');
  String get locating => _pick('Đang xác định vị trí…', 'Locating…');
  String get end => _pick('Kết thúc', 'End');
  String notificationError(Object error) => _pick(
    'Không bật được thông báo dẫn đường: $error',
    'Could not start navigation notification: $error',
  );
  String get navigating => _pick('Đang dẫn đường', 'Navigating');
  String get then => _pick('Sau đó ', 'Then ');
  String get rerouting => _pick('Đang tìm đường mới…', 'Rerouting…');
  String get gpsWeak => _pick('GPS yếu', 'Weak GPS');
  String get unmuteVoice => _pick('Bật giọng', 'Unmute voice');
  String get muteVoice => _pick('Tắt giọng', 'Mute voice');
  String get endHold => _pick('Kết thúc (giữ 1s)', 'End (hold 1s)');
  String get endNavigationTitle =>
      _pick('Kết thúc dẫn đường?', 'End navigation?');
  String get endNavigationMessage => _pick(
    'Bạn có chắc muốn dừng dẫn đường?',
    'Are you sure you want to stop navigation?',
  );
  String get continueNavigation => _pick('Tiếp tục', 'Continue');
  String get arrived => _pick('Đã đến nơi', 'Arrived');
  String get close => _pick('Đóng', 'Close');

  String get noHudConnected => _pick('Chưa kết nối HUD', 'HUD not connected');
  String get connectedStatus => _pick('ĐÃ KẾT NỐI', 'CONNECTED');
  String get connectingStatus => _pick('ĐANG KẾT NỐI', 'CONNECTING');
  String get disconnectedStatus => _pick('MẤT KẾT NỐI', 'DISCONNECTED');
  String get pairedStatus => _pick('ĐÃ GHÉP', 'PAIRED');
  String fwInfo(String version, int maxText, bool supportsDiacritics) {
    final suffix = supportsDiacritics
        ? _pick(' · có dấu', ' · accents supported')
        : '';
    return _pick(
      'FW $version · $maxText ký tự$suffix',
      'FW $version · $maxText chars$suffix',
    );
  }

  String get connect => _pick('Kết nối', 'Connect');
  String get sendTest => _pick('Gửi thử', 'Send test');
  String get disconnect => _pick('Ngắt', 'Disconnect');
  String get forget => _pick('Quên', 'Forget');
  String get nearbyNusDevices =>
      _pick('Thiết bị NUS gần đây', 'Nearby NUS devices');
  String get stop => _pick('Dừng', 'Stop');
  String get scan => _pick('Quét', 'Scan');
  String scanError(Object error) =>
      _pick('Lỗi quét: $error', 'Scan error: $error');
  String get scanPrompt => _pick(
    'Bấm Quét để tìm thiết bị quảng bá Nordic UART Service.',
    'Tap Scan to find devices advertising Nordic UART Service.',
  );
  String get scanningNus => _pick('Đang quét NUS…', 'Scanning NUS…');
  String get noHudFound => _pick(
    'Không tìm thấy HUD. Bật nguồn thiết bị và giữ nút pair.',
    'No HUD found. Power on the device and hold the pair button.',
  );
  String get autoReconnectTitle =>
      _pick('Tự kết nối lại khi mở app', 'Auto reconnect on app start');
  String get vibrateBleLostTitle =>
      _pick('Rung điện thoại khi mất BLE', 'Vibrate when BLE is lost');
  String get blePermissionRequired => _pick(
    'Cần cấp quyền Bluetooth để quét thiết bị HUD.',
    'Bluetooth permission is required to scan for HUD devices.',
  );
  String get blePermissionBlocked => _pick(
    'Quyền Bluetooth đang bị chặn. Mở Settings của Android để cấp Nearby devices/Bluetooth.',
    'Bluetooth permission is blocked. Open Android Settings to grant Nearby devices/Bluetooth.',
  );
  String blePermissionCheckError(Object error) => _pick(
    'Không kiểm tra được quyền Bluetooth: $error',
    'Could not check Bluetooth permissions: $error',
  );
  String get bluetoothOffBanner => _pick(
    'Bluetooth đang tắt. Bật để kết nối thiết bị HUD.',
    'Bluetooth is off. Turn it on to connect to your HUD device.',
  );
  String get turnOnBluetooth => _pick('Bật Bluetooth', 'Turn on');

  String get locationPermissionTitle =>
      _pick('Cần quyền vị trí', 'Location permission needed');
  String get locationPermissionMessage => _pick(
    'NavHUD cần quyền vị trí để định vị bạn trên bản đồ và dẫn đường.',
    'NavHUD needs location permission to show you on the map and navigate.',
  );
  String get locationServiceDisabledMessage => _pick(
    'Dịch vụ vị trí (GPS) đang tắt. Bật trong Cài đặt hệ thống để tiếp tục.',
    'Location services (GPS) are off. Turn them on in system settings to continue.',
  );
  String get locationPermissionDeniedForeverMessage => _pick(
    'Quyền vị trí đang bị chặn vĩnh viễn. Mở Cài đặt ứng dụng để cấp quyền.',
    'Location permission is permanently denied. Open app settings to grant it.',
  );
  String get grantPermission => _pick('Cấp quyền', 'Grant permission');
  String get openAppSettings => _pick('Mở Cài đặt', 'Open settings');
}

extension AppLocalizationsX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => AppLocalizations.supportedLocales.any(
    (supported) => supported.languageCode == locale.languageCode,
  );

  @override
  Future<AppLocalizations> load(Locale locale) =>
      SynchronousFuture(AppLocalizations(locale));

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}
