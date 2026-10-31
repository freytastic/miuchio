import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:miuchio/diagnostics/trace.dart';

part 'wordmark_glyphs.g.dart';

// A word written by hand. One baked texture holds the lettering and when the
// pen reaches each pixel; a fragment shader reveals it on a single rectangle,
// so a frame costs the same however complex the letters are. Only the progress
// uniform changes while it writes

// Build override for measuring: off shows the finished word without writing
const String _kMode = String.fromEnvironment('MIUCHIO_WORDMARK');

const String _kShaderAsset = 'shaders/wordmark.frag';

// Soft pen front as a share of the whole word
const double _kFront = 0.02;

class WordmarkGlyphs {
  const WordmarkGlyphs({
    required this.word,
    required this.width,
    required this.height,
    required this.asset,
  });

  final String word;
  final int width;
  final int height;
  final String asset;

  double get aspect => width / height;
}

// The shader and textures load once and stay resident; together they are
// under 2 MB of texture memory
abstract class WordmarkPrep {
  static Future<ui.FragmentProgram?>? _program;
  static final Map<String, Future<ui.Image?>> _images = {};

  // Start loading before the word is on screen
  static void prewarm(WordmarkGlyphs glyphs) {
    program();
    image(glyphs);
  }

  static Future<ui.FragmentProgram?> program() =>
      _program ??= ui.FragmentProgram.fromAsset(_kShaderAsset)
          .then<ui.FragmentProgram?>((p) => p, onError: (Object e) {
        Trace.event('wordmark.fallback', fields: {'shader': '$e'});
        return null;
      });

  static Future<ui.Image?> image(WordmarkGlyphs glyphs) =>
      _images.putIfAbsent(glyphs.asset, () async {
        try {
          final data = await rootBundle.load(glyphs.asset);
          final codec =
              await ui.instantiateImageCodec(data.buffer.asUint8List());
          final frame = await codec.getNextFrame();
          codec.dispose();
          return frame.image;
        } catch (e) {
          Trace.event('wordmark.fallback', fields: {'texture': '$e'});
          return null;
        }
      });
}

// Starts the pen, optionally on another animation's clock so it never drifts
class WordmarkCue extends ChangeNotifier {
  bool _started = false;
  bool _followClock = false;
  Duration _clock = Duration.zero;

  bool get started => _started;
  bool get followsClock => _followClock;
  Duration get clockTime => _clock;

  void start({bool followClock = false}) {
    if (_started) return;
    _started = true;
    _followClock = followClock;
    notifyListeners();
  }

  void tick(Duration time) {
    if (!_followClock) return;
    _clock = time;
    notifyListeners();
  }
}

class HelloWordmark extends StatefulWidget {
  const HelloWordmark({
    super.key,
    required this.glyphs,
    required this.height,
    required this.color,
    required this.duration,
    required this.semanticsLabel,
    this.cue,
  });

  final WordmarkGlyphs glyphs;
  final double height;
  final Color color;
  final Duration duration;
  final String semanticsLabel;

  // Null starts writing as soon as the texture is ready
  final WordmarkCue? cue;

  @override
  State<HelloWordmark> createState() => _HelloWordmarkState();
}

class _HelloWordmarkState extends State<HelloWordmark>
    with SingleTickerProviderStateMixin {
  // Created up front: a ticker built lazily from a cue callback could look up
  // ancestors after this copy started leaving the tree
  late final AnimationController _write;
  ui.FragmentShader? _shader;
  ui.Image? _map;
  bool _ready = false;
  bool _requested = false;

  @override
  void initState() {
    super.initState();
    _write = AnimationController(vsync: this, duration: widget.duration);
    widget.cue?.addListener(_drive);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_requested) return;
    _requested = true;
    if (_kMode == 'off' ||
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      _write.value = 1;
    }
    _load();
  }

  Future<void> _load() async {
    final watch = Stopwatch()..start();
    final program = await WordmarkPrep.program();
    final map = await WordmarkPrep.image(widget.glyphs);
    if (!mounted) return;
    setState(() {
      _shader = program?.fragmentShader();
      _map = map;
      _ready = true;
      // Without the shader the finished word is drawn straight away
      if (_shader == null) _write.value = 1;
    });
    Trace.event('wordmark.ready', fields: {
      'word': widget.glyphs.word,
      'ms': watch.elapsedMilliseconds,
      'shader': _shader != null,
    });
    _drive();
  }

  void _drive() {
    if (!_ready || _write.value >= 1) return;
    final cue = widget.cue;
    if (cue == null) {
      if (!_write.isAnimating) _write.forward();
      return;
    }
    if (!cue.started) return;
    if (cue.followsClock) {
      _write.value =
          (cue.clockTime.inMicroseconds / widget.duration.inMicroseconds)
              .clamp(0.0, 1.0);
      return;
    }
    if (!_write.isAnimating) _write.forward();
  }

  @override
  void dispose() {
    widget.cue?.removeListener(_drive);
    _write.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.glyphs;
    final size = Size(widget.height * g.aspect, widget.height);
    final map = _map;
    if (_ready && map == null) {
      // The texture failed to load, so fall back to plain text
      return SizedBox.fromSize(
        size: size,
        child: Center(
          child: Text(
            g.word,
            style: TextStyle(
              color: widget.color,
              fontSize: widget.height * 0.5,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      );
    }
    return Semantics(
      label: widget.semanticsLabel,
      image: true,
      child: RepaintBoundary(
        child: CustomPaint(
          size: size,
          painter: map == null
              ? null
              : _WordmarkPainter(
                  map: map,
                  shader: _shader,
                  write: _write,
                  color: widget.color,
                ),
        ),
      ),
    );
  }
}

class _WordmarkPainter extends CustomPainter {
  _WordmarkPainter({
    required this.map,
    required this.shader,
    required this.write,
    required this.color,
  }) : super(repaint: write);

  final ui.Image map;
  final ui.FragmentShader? shader;
  final Animation<double> write;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final progress = Curves.easeInOutCubic.transform(write.value);
    if (progress <= 0) return;
    final shader = this.shader;
    if (shader == null) {
      // Lettering coverage becomes alpha; no blend, so every renderer agrees
      canvas.drawImageRect(
        map,
        Offset.zero & Size(map.width.toDouble(), map.height.toDouble()),
        Offset.zero & size,
        Paint()
          ..filterQuality = FilterQuality.low
          ..colorFilter = ColorFilter.matrix(<double>[
            0, 0, 0, 0, color.r * 255, //
            0, 0, 0, 0, color.g * 255, //
            0, 0, 0, 0, color.b * 255, //
            color.a, 0, 0, 0, 0,
          ]),
      );
      return;
    }
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, progress)
      ..setFloat(3, _kFront)
      ..setFloat(4, color.r)
      ..setFloat(5, color.g)
      ..setFloat(6, color.b)
      ..setFloat(7, color.a)
      ..setImageSampler(0, map, filterQuality: FilterQuality.low);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_WordmarkPainter old) =>
      old.map != map || old.shader != shader || old.color != color;
}
