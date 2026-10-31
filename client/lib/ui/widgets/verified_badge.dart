import 'package:flutter/material.dart';

import 'package:miuchio/ui/theme/warm_tokens.dart';

// Marks a person whose security code was compared and matched. It sits on
// their face like a seal, in ink rather than a signal color, so verified reads
// as settled and never as an alert
class VerifiedBadge extends StatelessWidget {
  final double size;

  const VerifiedBadge({super.key, this.size = 16});

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('verified-badge'),
        width: size + 3,
        height: size + 3,
        alignment: Alignment.center,
        decoration:
            const BoxDecoration(color: Warm.ground, shape: BoxShape.circle),
        child: Icon(Icons.verified_rounded, size: size, color: Warm.ink),
      );
}

// A face with the badge on its lower right when verified
class BadgedFace extends StatelessWidget {
  final Widget face;
  final double size;
  final bool verified;

  const BadgedFace({
    super.key,
    required this.face,
    required this.size,
    required this.verified,
  });

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(child: face),
            if (verified)
              Positioned(
                right: -3,
                bottom: -3,
                child: VerifiedBadge(size: size * 0.4),
              ),
          ],
        ),
      );
}
