import 'package:flutter/material.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/frozen_backdrop.dart';

class BlurScrim extends StatelessWidget {
  final Animation<double> progress;
  final double sigma;
  final double saturation;
  final Color color;
  final VoidCallback? onTap;

  const BlurScrim({
    super.key,
    required this.progress,
    required this.color,
    this.sigma = Warm.peekBlur,
    this.saturation = Warm.peekSaturation,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scrim = FrozenBackdrop(
      sigma: sigma,
      saturation: saturation,
      color: color,
      opacity: progress,
      blendMode: BlendMode.src,
    );
    if (onTap == null) return scrim;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: scrim,
    );
  }
}
