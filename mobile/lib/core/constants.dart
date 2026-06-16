/// Cấu hình endpoint & khoá API. Trong sản phẩm thật nên đọc từ
/// `--dart-define` / secure storage, không hardcode.
class AppConfig {
  AppConfig._();

  /// Valhalla routing (self-host hoặc API). Đặt base URL của bạn.
  static const String valhallaBaseUrl = String.fromEnvironment(
    'VALHALLA_URL',
    defaultValue: 'https://valhalla1.openstreetmap.de',
  );

  /// Goong.io (geocoding + tiles VN). Để trống nếu dùng Nominatim/OSM.
  static const String goongApiKey = String.fromEnvironment(
    'GOONG_API_KEY',
    defaultValue: '',
  );
  static const String goongBaseUrl = 'https://rsapi.goong.io';

  /// Nominatim (fallback geocoding miễn phí).
  static const String nominatimBaseUrl = 'https://nominatim.openstreetmap.org';
  static const String nominatimCountryCodes = String.fromEnvironment(
    'NOMINATIM_COUNTRY_CODES',
    defaultValue: 'vn',
  );
  static const String nominatimAcceptLanguage = String.fromEnvironment(
    'NOMINATIM_ACCEPT_LANGUAGE',
    defaultValue: 'vi,en',
  );
  static const String nominatimUserAgent = String.fromEnvironment(
    'NOMINATIM_USER_AGENT',
    defaultValue: 'NavHUD/0.1',
  );

  /// Overpass API cho biển báo (§4.4).
  static const String overpassUrl = 'https://overpass-api.de/api/interpreter';

  /// MapLibre style JSON. Goong / MapTiler / OpenFreeMap.
  /// Mặc định dùng OpenFreeMap (vector tiles miễn phí, không cần API key,
  /// có dữ liệu đường phố đầy đủ — kể cả VN). Production nên override bằng
  /// --dart-define=MAP_STYLE_URL=... (MapTiler/Goong) để có SLA + attribution.
  /// demotiles.maplibre.org chỉ có dữ liệu zoom thấp → KHÔNG dùng làm nền phố.
  static const String mapStyleUrl = String.fromEnvironment(
    'MAP_STYLE_URL',
    defaultValue: 'https://tiles.openfreemap.org/styles/liberty',
  );
  static const String mapStyleDarkUrl = String.fromEnvironment(
    'MAP_STYLE_DARK_URL',
    defaultValue: 'https://tiles.openfreemap.org/styles/positron',
  );

  // ── Navigation tuning (§4.3) ──────────────────────────────────────
  static const double arriveRadiusM = 25;
  static const int offRouteConsecutiveFixes = 3;
  static const List<double> voicePromptThresholdsM = [1000, 300, 100, 30];
  static const Duration gpsInterval = Duration(seconds: 1);
}
