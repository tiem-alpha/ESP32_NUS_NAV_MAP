import '../models/route_model.dart';
import '../models/traffic_sign.dart';

/// Interface lấy biển báo dọc tuyến (§4.4).
///
/// Giữ interface-driven (§2.2): nav engine phụ thuộc abstraction này,
/// implementation cụ thể (Overpass, mock, cache…) inject qua provider.
abstract class ISignService {
  /// Trả về danh sách biển báo dọc theo [route], đã gắn `offsetM`
  /// (mét tính từ điểm đầu tuyến) và sort tăng dần theo offset.
  ///
  /// Best-effort: lỗi mạng/parse → trả `const []`, không throw.
  Future<List<TrafficSign>> signsAlongRoute(RouteModel route);
}
