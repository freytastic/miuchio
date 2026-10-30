import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';

// The app icon's mark, drawn from brand/icon.svg. Coordinates are icon units,
// the svg's 100 x 100 viewBox

// The part of icon space the stage shows, centred on the icon like the m is
const Rect _kView = Rect.fromLTRB(14, 19, 86, 83);
const double _kStageWidthFactor = 0.3;
const double _kStageTopFactorShrunk = 0.01;
const double _kStageShrunkScale = 0.5;
const double _kStageMinScale = 0.6;
// Least air kept between the status bar and the mark at rest
const double _kRestTopClearance = 8;
const Duration _kShrinkDuration = Duration(milliseconds: 280);
const Curve _kShrinkCurve = Curves.easeOutCubic;

const double _kStroke = 10;
// The paper ring the icon cuts around the m
const double _kGap = 17;

class MarkStage extends StatelessWidget {
  const MarkStage({super.key});

  // At rest the mark stands on restBottom, so it reads as one lockup with the
  // wordmark under it. Shrunk, it moves up out of the keyboard's way
  static Widget positioned(
    BuildContext context, {
    required double restBottom,
    bool shrink = false,
    double shrunkScale = _kStageShrunkScale,
  }) {
    final size = MediaQuery.sizeOf(context);
    final width = size.width * _kStageWidthFactor;
    final height = _height(width);
    // viewPadding is stable while the keyboard opens
    final topInset = MediaQuery.viewPaddingOf(context).top;
    // Short screens trade some of the mark's size for room under the bar
    final restScale =
        ((restBottom - topInset - _kRestTopClearance) / height)
            .clamp(_kStageMinScale, 1.0)
            .toDouble();
    return AnimatedPositioned(
      duration: _kShrinkDuration,
      curve: _kShrinkCurve,
      left: (size.width - width) / 2,
      top: shrink
          ? topInset + size.height * _kStageTopFactorShrunk
          : restBottom - height * restScale,
      width: width,
      height: height,
      child: AnimatedScale(
        duration: _kShrinkDuration,
        curve: _kShrinkCurve,
        alignment: Alignment.topCenter,
        scale: shrink ? shrunkScale : restScale,
        child: const MarkStage(),
      ),
    );
  }

  static double _height(double width) => width * _kView.height / _kView.width;

  static double _unscaledHeight(BuildContext context) =>
      _height(MediaQuery.sizeOf(context).width * _kStageWidthFactor);

  static double shrunkScaleToFit(
    BuildContext context, {
    required double maxVisualBottom,
  }) {
    final top = MediaQuery.viewPaddingOf(context).top +
        MediaQuery.sizeOf(context).height * _kStageTopFactorShrunk;
    final unscaledHeight = _unscaledHeight(context);
    if (unscaledHeight <= 0) return _kStageShrunkScale;
    return ((maxVisualBottom - top) / unscaledHeight)
        .clamp(0.0, _kStageShrunkScale)
        .toDouble();
  }

  static double shrunkVisualBottom(
    BuildContext context, {
    required double scale,
  }) {
    final top = MediaQuery.viewPaddingOf(context).top +
        MediaQuery.sizeOf(context).height * _kStageTopFactorShrunk;
    return top + _unscaledHeight(context) * scale;
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
