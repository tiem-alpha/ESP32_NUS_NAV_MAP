import 'package:flutter/material.dart';

import '../../models/maneuver_type.dart';

/// Icon maneuver dựng từ Material Icons (assets/icons/maneuvers/ đang rỗng —
/// không load SVG để tránh crash). Map ManeuverType → IconData. (§11.6)
class ManeuverIcon extends StatelessWidget {
  final ManeuverType type;
  final double size;
  final Color? color;

  const ManeuverIcon(
    this.type, {
    super.key,
    this.size = 48,
    this.color,
  });

  static IconData iconFor(ManeuverType type) {
    switch (type) {
      case ManeuverType.depart:
        return Icons.navigation;
      case ManeuverType.straight:
        return Icons.straight;
      case ManeuverType.turnSlightLeft:
        return Icons.turn_slight_left;
      case ManeuverType.turnLeft:
        return Icons.turn_left;
      case ManeuverType.turnSharpLeft:
        return Icons.turn_sharp_left;
      case ManeuverType.uturn:
        return Icons.u_turn_left;
      case ManeuverType.turnSharpRight:
        return Icons.turn_sharp_right;
      case ManeuverType.turnRight:
        return Icons.turn_right;
      case ManeuverType.turnSlightRight:
        return Icons.turn_slight_right;
      case ManeuverType.roundabout:
        return Icons.roundabout_right;
      case ManeuverType.exitLeft:
        return Icons.fork_left;
      case ManeuverType.exitRight:
        return Icons.fork_right;
      case ManeuverType.merge:
        return Icons.merge;
      case ManeuverType.ferry:
        return Icons.directions_boat;
      case ManeuverType.arrive:
        return Icons.place;
      case ManeuverType.arriveLeft:
        return Icons.place;
      case ManeuverType.arriveRight:
        return Icons.place;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Icon(
      iconFor(type),
      size: size,
      color: color ?? Theme.of(context).colorScheme.onSurface,
    );
  }
}
