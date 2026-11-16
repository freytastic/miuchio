import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:miuchio/diagnostics/fx.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/peek_route.dart';

// Blurs the still route behind once instead of every frame and stands in for
// it while this route is open, otherwise the filter stays live
class FrozenBackdrop extends StatefulWidget {
  final double sigma;
  final double saturation;
  final Color color;
  final Animation<double> opacity;
  final BlendMode blendMode;

  const FrozenBackdrop({
    super.key,
    required this.sigma,
    required this.saturation,
    required this.color,
    this.opacity = kAlwaysCompleteAnimation,
    this.blendMode = BlendMode.srcOver,
  });

  // Blur radius in snapshot pixels, more is invisible once upscaled
  static const double _sigmaPx = 8;

  @override
  State<FrozenBackdrop> createState() => _FrozenBackdropState();
}

class _FrozenBackdropState extends State<FrozenBackdrop> {
  ui.Image? _sharp;
  ui.Image? _blurred;
  Rect _screen = Rect.zero;

  @override
  void initState() {
    super.initState();
    // A frame later the route behind no longer shows what this route lifts
    if (!Fx.noBlur) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _freeze());
    }
  }

  @override
  void dispose() {
    _sharp?.dispose();
    _blurred?.dispose();
    super.dispose();
  }

  ui.ImageFilter _filter(double sigma, {TileMode? tileMode, Rect? bounds}) =>
      ui.ImageFilter.compose(
        outer: ui.ImageFilter.blur(
            sigmaX: sigma, sigmaY: sigma, tileMode: tileMode, bounds: bounds),
        inner: ui.ColorFilter.matrix(Warm.saturation(widget.saturation)),
      );

  void _freeze() {
    if (!mounted || widget.sigma <= 0) return;
    final route = ModalRoute.of(context);
    final behind = route is RouteBehind ? route.behind : null;
    if (behind == null || !behind.opaque || !behind.isActive) return;
    final box = behind.subtreeContext?.findRenderObject();
    if (box is! RenderRepaintBoundary || !box.attached || !box.hasSize) return;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final scale = math.min(dpr, FrozenBackdrop._sigmaPx / widget.sigma);
    final shots = _capture(box, dpr, scale);
    if (shots == null) return;
    setState(() {
      _sharp = shots.sharp;
      _blurred = shots.blurred;
      _screen = MatrixUtils.transformRect(
          box.getTransformTo(null), Offset.zero & box.size);
    });
    _hideBehind(true);
  }

  // Frees every image on failure so the live filter takes over
  ({ui.Image sharp, ui.Image blurred})? _capture(
      RenderRepaintBoundary box, double dpr, double scale) {
    ui.Image? sharp, small;
    ui.Picture? picture;
    try {
      sharp = box.toImageSync(pixelRatio: dpr);
      small = box.toImageSync(pixelRatio: scale);
      picture = _bake(small, widget.sigma * scale);
      final shots = (
        sharp: sharp,
        blurred: picture.toImageSync(small.width, small.height),
      );
      sharp = null;
      return shots;
    } catch (_) {
      return null;
    } finally {
      sharp?.dispose();
      small?.dispose();
      picture?.dispose();
    }
  }

  ui.Picture _bake(ui.Image small, double sigma) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final Paint paint;
    if (widget.blendMode == BlendMode.src) {
      // Keeps the dark edge rim of the live src filter
      canvas.drawColor(const Color(0xFF000000), BlendMode.src);
      paint = Paint()..imageFilter = _filter(sigma, tileMode: TileMode.decal);
    } else {
      final size = Size(small.width.toDouble(), small.height.toDouble());
      paint = Paint()..imageFilter = _filter(sigma, bounds: Offset.zero & size);
    }
    canvas
      ..drawImage(small, Offset.zero, paint)
      ..drawColor(widget.color, BlendMode.srcOver);
    return recorder.endRecording();
  }

  void _hideBehind(bool hide) {
    final route = ModalRoute.of(context);
    if (route is RouteBehind) route.hidesBehind = hide;
  }

  @override
  Widget build(BuildContext context) {
    final sharp = _sharp, blurred = _blurred;
    final fits = MediaQuery.sizeOf(context) == _screen.size;
    if (sharp != null && blurred != null) {
      if (fits) {
        return RepaintBoundary(
          child: _FrozenPaint(
            sharp: sharp,
            blurred: blurred,
            screen: _screen,
            opacity: widget.opacity,
            route: ModalRoute.of(context)!.animation!,
          ),
        );
      }
      // The overlay cannot change while it builds
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _hideBehind(false);
      });
    }
    return FadeTransition(
      opacity: widget.opacity,
      child: Fx.noBlur
          ? ColoredBox(color: widget.color)
          : BackdropFilter(
              blendMode: widget.blendMode,
              filter: _filter(widget.sigma),
              child: ColoredBox(color: widget.color),
            ),
    );
  }
}

class _FrozenPaint extends LeafRenderObjectWidget {
  final ui.Image sharp;
  final ui.Image blurred;
  final Rect screen;
  final Animation<double> opacity;
  final Animation<double> route;

  const _FrozenPaint({
    required this.sharp,
    required this.blurred,
    required this.screen,
    required this.opacity,
    required this.route,
  });

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFrozen(sharp, blurred, screen, opacity, route);

  @override
  void updateRenderObject(BuildContext context, _RenderFrozen render) {
    render
      ..images(sharp, blurred)
      ..screen = screen
      ..listen(opacity, route);
  }
}

class _RenderFrozen extends RenderBox {
  ui.Image _sharp;
  ui.Image _blurred;
  Rect _screen;
  Animation<double> _opacity;
  Animation<double> _route;

  _RenderFrozen(
      this._sharp, this._blurred, this._screen, this._opacity, this._route);

  void images(ui.Image sharp, ui.Image blurred) {
    if (identical(sharp, _sharp) && identical(blurred, _blurred)) return;
    _sharp = sharp;
    _blurred = blurred;
    markNeedsPaint();
  }

  set screen(Rect v) {
    if (v == _screen) return;
    _screen = v;
    markNeedsPaint();
  }

  void listen(Animation<double> opacity, Animation<double> route) {
    if (identical(opacity, _opacity) && identical(route, _route)) return;
    if (attached) _unlisten();
    _opacity = opacity;
    _route = route;
    if (attached) _listen();
    markNeedsPaint();
  }

  void _listen() {
    _opacity.addListener(markNeedsPaint);
    _route.addListener(markNeedsPaint);
  }

  void _unlisten() {
    _opacity.removeListener(markNeedsPaint);
    _route.removeListener(markNeedsPaint);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _listen();
  }

  @override
  void detach() {
    _unlisten();
    super.detach();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    final a = _opacity.value.clamp(0.0, 1.0);
    // Pinned to the screen while the route slides
    final origin = localToGlobal(Offset.zero);
    final dst = _screen.shift(offset - origin);
    final canvas = context.canvas;
    final covered = a == 1 && dst == offset & size;
    if (_route.status.isForwardOrCompleted && !covered) {
      _draw(canvas, _sharp, dst, Paint());
    }
    if (a == 0) return;
    canvas
      ..save()
      ..clipRect(offset & size);
    _draw(
        canvas,
        _blurred,
        dst,
        Paint()
          ..filterQuality = FilterQuality.low
          ..color = Color.fromRGBO(0, 0, 0, a));
    canvas.restore();
  }

  void _draw(Canvas canvas, ui.Image image, Rect dst, Paint paint) {
    final src =
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    canvas.drawImageRect(image, src, dst, paint);
  }
}
