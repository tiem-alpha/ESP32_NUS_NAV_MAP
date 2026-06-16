import 'maneuver_type.dart';
import 'route_model.dart';
import 'nav_state.dart';
import 'traffic_sign.dart';

/// Sự kiện dẫn đường phát lên event bus (§2.2, §4.3).
///
/// Navigation Engine không biết gì về BLE — nó phát `NavEvent`; BLE Bridge,
/// UI, TTS… là các *subscriber* độc lập. Thêm subscriber (Wear OS, Android Auto)
/// không phải sửa engine.
sealed class NavEvent {
  const NavEvent();
}

/// Sang maneuver mới → đẩy NAV_INSTRUCTION xuống HUD + đọc TTS.
class InstructionChanged extends NavEvent {
  final Maneuver maneuver;
  final int seq; // tăng dần, phục vụ ACK
  final Maneuver? nextManeuver;
  const InstructionChanged(this.maneuver, this.seq, {this.nextManeuver});
}

/// Mỗi 1 s (1 GPS fix) → DISTANCE_TICK (write no-response).
class DistanceTick extends NavEvent {
  final double distanceToManeuverM;
  final double distanceRemainingM;
  final double etaSeconds;
  final double speedKmh;
  const DistanceTick({
    required this.distanceToManeuverM,
    required this.distanceRemainingM,
    required this.etaSeconds,
    required this.speedKmh,
  });
}

class SpeedLimitChanged extends NavEvent {
  final int limitKmh; // 0 = unknown
  final bool isOver;
  const SpeedLimitChanged(this.limitKmh, this.isOver);
}

class SignApproaching extends NavEvent {
  final TrafficSign sign;
  final double distanceM;
  const SignApproaching(this.sign, this.distanceM);
}

class PhaseChanged extends NavEvent {
  final NavPhase phase;
  const PhaseChanged(this.phase);
}

class Rerouting extends NavEvent {
  const Rerouting();
}

class Arrived extends NavEvent {
  const Arrived();
}

/// Nhắc bằng giọng nói tại ngưỡng 1000/300/100 m / "bây giờ" (§4.3 mục 5).
class VoicePrompt extends NavEvent {
  final String text; // tiếng Việt
  final ManeuverType maneuver;
  const VoicePrompt(this.text, this.maneuver);
}
