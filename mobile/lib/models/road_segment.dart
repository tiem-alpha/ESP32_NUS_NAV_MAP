import 'geo_point.dart';

enum HighwayType {
  motorway(0),
  trunk(1),
  primary(2),
  secondary(3),
  tertiary(4),
  residential(5),
  service(6);

  final int value;
  const HighwayType(this.value);

  static HighwayType fromOsmTag(String tag) {
    switch (tag) {
      case 'motorway':
      case 'motorway_link':
        return HighwayType.motorway;
      case 'trunk':
      case 'trunk_link':
        return HighwayType.trunk;
      case 'primary':
      case 'primary_link':
        return HighwayType.primary;
      case 'secondary':
      case 'secondary_link':
        return HighwayType.secondary;
      case 'tertiary':
      case 'tertiary_link':
        return HighwayType.tertiary;
      case 'residential':
      case 'living_street':
      case 'unclassified':
        return HighwayType.residential;
      default:
        return HighwayType.service;
    }
  }
}

class RoadSegment {
  final HighwayType type;
  final List<GeoPoint> points;

  const RoadSegment({required this.type, required this.points});
}
