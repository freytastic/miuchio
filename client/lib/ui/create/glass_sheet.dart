import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/frozen_backdrop.dart';

// Warm blurred overlay that keeps the shelf visible
class GlassSheet extends StatelessWidget {
  final Widget child;

  const GlassSheet({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const FrozenBackdrop(
          sigma: Warm.glassBlur,
          saturation: Warm.glassSaturation,
          color: Warm.glassScrim,
        ),
        child,
      ],
    );
  }

  static final ui.ImageFilter filter = ui.ImageFilter.compose(
    outer: ui.ImageFilter.blur(sigmaX: Warm.glassBlur, sigmaY: Warm.glassBlur),
    inner: ui.ColorFilter.matrix(Warm.saturation(Warm.glassSaturation)),
  );
}

// The same glass on a panel. The blur is clipped to the panel, so it costs
// only the area it covers
class GlassPanel extends StatelessWidget {
  final Widget child;
  final BorderRadius radius;

  const GlassPanel({super.key, required this.child, required this.radius});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: GlassSheet.filter,
        child: ColoredBox(color: Warm.glassScrim, child: child),
      ),
    );
  }
}
