import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';

// The app icon's mark, drawn from brand/icon.svg. Coordinates are icon units,
// the svg's 100 x 100 viewBox

// The part of icon space the stage shows, centred on the icon like the m is
const Rect _kView = Rect.fromLTRB(14, 19, 86, 83);
const double _kStageWidthFactor = 0.3;
const Duration _kMoveDuration = Duration(milliseconds: 280);
const Curve _kMoveCurve = Curves.easeOutCubic;

// The native launch image is rendered from this widget at this width, so the
// launch screen and the loading page show the same mark in the same place
const double kLaunchMarkWidth = 126;

const double _kStroke = 10;
// The paper ring the icon cuts around the m
const double _kGap = 17;

class MarkStage extends StatelessWidget {
  const MarkStage({super.key});

  // The mark flies from the loading page into onboarding under this tag
  static const Object heroTag = 'miuchio-mark';

  static double heightFor(double width) =>
      width * _kView.height / _kView.width;

  // Unscaled height of the onboarding mark on this screen
  static double stageHeight(BuildContext context) =>
      heightFor(MediaQuery.sizeOf(context).width * _kStageWidthFactor);

  // The mark stands on bottom and scales about its base, so it moves in step
  // with the copy under it, which animates with the same duration and curve
  static Widget positioned(
    BuildContext context, {
    required double bottom,
    double scale = 1,
  }) {
    final size = MediaQuery.sizeOf(context);
    final width = size.width * _kStageWidthFactor;
    return AnimatedPositioned(
      duration: _kMoveDuration,
      curve: _kMoveCurve,
      left: (size.width - width) / 2,
      bottom: size.height - bottom,
      width: width,
      height: heightFor(width),
      child: AnimatedScale(
        duration: _kMoveDuration,
        curve: _kMoveCurve,
        alignment: Alignment.bottomCenter,
        scale: scale,
        child: const _Flying(child: MarkStage()),
      ),
    );
  }

  // The loading page's mark, the size of the native launch image
  static Widget launch() {
    return SizedBox(
      width: kLaunchMarkWidth,
      height: heightFor(kLaunchMarkWidth),
      child: const _Flying(child: MarkStage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Miuchio logo',
      image: true,
      child: const RepaintBoundary(
        child: CustomPaint(size: Size.infinite, painter: _MarkPainter()),
      ),
    );
  }
}

class _Flying extends StatelessWidget {
  const _Flying({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Hero(
      tag: MarkStage.heroTag,
      // A straight glide rather than Material's arc
      createRectTween: (begin, end) => RectTween(begin: begin, end: end),
      child: child,
    );
  }
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter();

  static final Path _m = Path()
    ..moveTo(24, 76)
    ..lineTo(24, 56)
    ..arcToPoint(const Offset(47, 56), radius: const Radius.circular(11.5))
    ..lineTo(47, 76)
    ..moveTo(47, 56)
    ..arcToPoint(const Offset(70, 56), radius: const Radius.circular(11.5))
    ..lineTo(70, 76);

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width / _kView.width;
    canvas.save();
    canvas.scale(unit);
    canvas.translate(-_kView.left, -_kView.top);

    // The print sits behind the m, with the paper ring cut out of it
    canvas.saveLayer(_kView, Paint());
    canvas.save();
    canvas.translate(68, 39);
    canvas.rotate(14 * math.pi / 180);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(-12.5, -15, 25, 30), const Radius.circular(2.2)),
      Paint()..color = Warm.cta,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(-9.5, -12, 19, 19), const Radius.circular(1)),
      Paint()..color = Warm.orbPeach,
    );
    canvas.restore();
    canvas.drawPath(_m, _line(_kGap)..blendMode = BlendMode.clear);
    canvas.restore();

    canvas.drawPath(_m, _line(_kStroke)..color = Warm.cta);
    canvas.restore();
  }

  static Paint _line(double width) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;

  @override
  bool shouldRepaint(_MarkPainter oldDelegate) => false;
}
