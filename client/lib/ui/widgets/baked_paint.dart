import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

typedef BakedPainter = void Function(Canvas canvas, Size size);

// Cache static blur effects to avoid repainting the blur each frame
class BakedPaint extends StatefulWidget {
  // Include paint changes in the ID; size is added to the cache key
  final String id;
  final EdgeInsets overflow;
  final double maxScale;
  final BakedPainter painter;

  // Inset to an area always hidden under something opaque, never drawn
  final EdgeInsets? covered;

  const BakedPaint({
    super.key,
    required this.id,
    required this.painter,
    this.overflow = EdgeInsets.zero,
    this.maxScale = 3,
    this.covered,
  });

  // Lets an animation start only once the blur is baked, never live
  static Future<void> warm({
    required String id,
    required Size size,
    required double devicePixelRatio,
    required BakedPainter painter,
    EdgeInsets overflow = EdgeInsets.zero,
    double maxScale = 3,
  }) async {
    if (!size.isFinite || size.isEmpty) return;
    final scale =
        devicePixelRatio < maxScale ? devicePixelRatio : maxScale;
    final key = _BakedPaintState._keyFor(id, size, scale);
    if (_BakedPaintState._cache.containsKey(key)) return;
    // Do not return the removed future or it would await itself
    final image = await (_BakedPaintState._pending[key] ??=
        _BakedPaintState._bake(painter, overflow, size, scale)
            .whenComplete(() {
      _BakedPaintState._pending.remove(key);
    }));
    _BakedPaintState._store(key, image);
  }

  @override
  State<BakedPaint> createState() => _BakedPaintState();
}

class _BakedPaintState extends State<BakedPaint> {
  static final LinkedHashMap<String, ui.Image> _cache = LinkedHashMap();
  static final Map<String, Future<ui.Image>> _pending = {};
  static const int _maxEntries = 24;
  static const Duration _settle = Duration(milliseconds: 120);

  ui.Image? _image;
  String? _imageKey;
  String? _wanted;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _image?.dispose();
    super.dispose();
  }

  static String _keyFor(String id, Size size, double scale) =>
      '$id|${size.width.toStringAsFixed(1)}x${size.height.toStringAsFixed(1)}@$scale';

  void _use(String key, ui.Image shared) {
    if (_imageKey == key) return;
    _image?.dispose();
    _image = shared.clone();
    _imageKey = key;
  }

  void _want(String key, Size size, double scale) {
    if (_wanted == key) return;
    _wanted = key;
    _timer?.cancel();
    // Wait for resizing to stop before allocating a cached image
    _timer = Timer(_settle, () async {
      if (!mounted || _wanted != key) return;
      try {
        // Do not return the removed future or it would await itself
        final image = await (_pending[key] ??=
            _bake(widget.painter, widget.overflow, size, scale)
                .whenComplete(() {
          _pending.remove(key);
        }));
        _store(key, image);
        if (mounted && _wanted == key) setState(() {});
      } catch (_) {
      }
    });
  }

  static Future<ui.Image> _bake(
      BakedPainter painter, EdgeInsets o, Size size, double scale) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..scale(scale)
      ..translate(o.left, o.top);
    painter(canvas, size);
    final picture = recorder.endRecording();
    return picture
        .toImage(((size.width + o.horizontal) * scale).ceil(),
            ((size.height + o.vertical) * scale).ceil())
        .whenComplete(picture.dispose);
  }

  static void _store(String key, ui.Image image) {
    if (_cache.containsKey(key)) {
      if (!identical(_cache[key], image)) image.dispose();
      return;
    }
    _cache[key] = image;
    while (_cache.length > _maxEntries) {
      // Widget clones remain valid after cache eviction
      _cache.remove(_cache.keys.first)?.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.biggest;
      if (!size.isFinite || size.isEmpty) return const SizedBox.shrink();
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final scale = dpr < widget.maxScale ? dpr : widget.maxScale;
      final key = _keyFor(widget.id, size, scale);
      final cached = _cache[key];
      if (cached != null) {
        _use(key, cached);
      } else {
        _want(key, size, scale);
      }
      final image = _imageKey == key ? _image : null;
      return CustomPaint(
        size: size,
        painter: image != null
            ? _ImagePainter(image, widget.overflow, widget.covered)
            : _LivePainter(widget.painter, widget.id),
      );
    });
  }
}

class _ImagePainter extends CustomPainter {
  final ui.Image image;
  final EdgeInsets overflow;
  final EdgeInsets? covered;

  _ImagePainter(this.image, this.overflow, this.covered);

  @override
  void paint(Canvas canvas, Size size) {
    final dst = Rect.fromLTWH(-overflow.left, -overflow.top,
        size.width + overflow.horizontal, size.height + overflow.vertical);
    final paint = Paint()..filterQuality = FilterQuality.low;
    final hole = covered?.deflateRect(Offset.zero & size);
    if (hole == null || hole.isEmpty) {
      canvas.drawImageRect(image, _src(dst, dst), dst, paint);
      return;
    }
    // Skips the covered middle, soft images are fill bound on slow GPUs
    for (final part in [
      Rect.fromLTRB(dst.left, dst.top, dst.right, hole.top),
      Rect.fromLTRB(dst.left, hole.bottom, dst.right, dst.bottom),
      Rect.fromLTRB(dst.left, hole.top, hole.left, hole.bottom),
      Rect.fromLTRB(hole.right, hole.top, dst.right, hole.bottom),
    ]) {
      if (!part.isEmpty) {
        canvas.drawImageRect(image, _src(part, dst), part, paint);
      }
    }
  }

  Rect _src(Rect part, Rect dst) {
    final sx = image.width / dst.width, sy = image.height / dst.height;
    return Rect.fromLTRB((part.left - dst.left) * sx, (part.top - dst.top) * sy,
        (part.right - dst.left) * sx, (part.bottom - dst.top) * sy);
  }

  @override
  bool shouldRepaint(_ImagePainter old) =>
      !identical(old.image, image) ||
      old.overflow != overflow ||
      old.covered != covered;
}

class _LivePainter extends CustomPainter {
  final BakedPainter painter;
  final String id;

  _LivePainter(this.painter, this.id);

  @override
  void paint(Canvas canvas, Size size) => painter(canvas, size);

  @override
  bool shouldRepaint(_LivePainter old) => old.id != id;
}
