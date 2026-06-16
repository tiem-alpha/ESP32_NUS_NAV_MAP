import 'geo_point.dart';

/// Loại địa điểm (để chọn icon ở S2).
enum PlaceKind { generic, home, work, history, favorite, food, fuel, parking }

/// Kết quả geocoding / mục lịch sử / favorite (§4.1, S2).
class Place {
  final String id;
  final String name; // tên chính
  final String address; // địa chỉ phụ (xám)
  final GeoPoint location;
  final PlaceKind kind;

  const Place({
    required this.id,
    required this.name,
    required this.address,
    required this.location,
    this.kind = PlaceKind.generic,
  });

  Place copyWith({PlaceKind? kind}) => Place(
        id: id,
        name: name,
        address: address,
        location: location,
        kind: kind ?? this.kind,
      );
}
