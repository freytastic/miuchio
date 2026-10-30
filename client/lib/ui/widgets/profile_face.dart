import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';

// Your own picture as a round profile photo with a camera badge, the same in
// onboarding and on the You tab. A print would read as an album
class ProfileFace extends StatelessWidget {
  final Uint8List? photo;
  final bool busy;
  final double size;
  // Drawn in the well while there is no photo
  final Widget? placeholder;

  const ProfileFace({
    super.key,
    required this.photo,
    this.busy = false,
    this.size = 176,
    this.placeholder,
  });

  @override
  Widget build(BuildContext context) {
    final p = photo;
    final badge = (size * 0.23).roundToDouble();
    final inset = size * 0.034;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Warm.wellEmpty,
              border: Border.all(color: Warm.paper, width: size * 0.028),
              boxShadow: [
                BoxShadow(
                    color: Warm.shadow(0.10),
                    blurRadius: 18,
                    offset: const Offset(0, 8)),
              ],
            ),
            child: ClipOval(
              child: AnimatedSwitcher(
                duration: Warm.quick,
                child: p == null
                    ? SizedBox.expand(child: placeholder)
                    : Image.memory(p,
                        key: ObjectKey(p),
                        fit: BoxFit.cover,
                        width: size,
                        height: size,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) =>
                            SizedBox.expand(child: placeholder)),
              ),
            ),
          ),
          Positioned(
            right: inset,
            bottom: inset,
            child: Container(
              width: badge,
              height: badge,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Warm.cta,
                border: Border.all(color: Warm.ground, width: 3),
              ),
              child: busy
                  ? SizedBox(
                      width: badge * 0.35,
                      height: badge * 0.35,
                      child: const CircularProgressIndicator(
                          strokeWidth: 1.8, color: Warm.ctaInk),
                    )
                  : Icon(Icons.photo_camera_outlined,
                      size: badge * 0.45, color: Warm.ctaInk),
            ),
          ),
        ],
      ),
    );
  }
}
