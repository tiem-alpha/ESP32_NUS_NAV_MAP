import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';

/// Biển tốc độ kiểu VN: vòng tròn viền đỏ, nền trắng, số đen ở giữa.
/// Đỏ rực (glow) khi quá tốc độ. Ẩn khi [limit] <= 0. (§11.6)
class SpeedSign extends StatelessWidget {
  final int limit;
  final bool isOver;
  final double size;

  const SpeedSign({
    super.key,
    required this.limit,
    this.isOver = false,
    this.size = 56,
  });

  @override
  Widget build(BuildContext context) {
    if (limit <= 0) return const SizedBox.shrink();

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.speedSignFill,
        shape: BoxShape.circle,
        border: Border.all(
          color: AppColors.speedSignBorder,
          width: size * 0.11,
        ),
        boxShadow: isOver
            ? [
                BoxShadow(
                  color: AppColors.dangerLight.withValues(alpha: 0.85),
                  blurRadius: 16,
                  spreadRadius: 2,
                ),
              ]
            : const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 4,
                  offset: Offset(0, 1),
                ),
              ],
      ),
      child: Text(
        '$limit',
        style: AppTypography.speedSign(Colors.black)
            .copyWith(fontSize: size * 0.4),
      ),
    );
  }
}
