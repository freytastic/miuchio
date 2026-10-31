import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:miuchio/diagnostics/trace.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/print_card.dart';

const List<String> _kPhotos = [
  'lib/assets/onboarding/picnic_1.jpg',
  'lib/assets/onboarding/picnic_2.jpg',
  'lib/assets/onboarding/picnic_3.jpg',
];
// Already at their painted size, so they decode as they are
const List<String> _kFaces = [
  'lib/assets/onboarding/face_1.jpg',
  'lib/assets/onboarding/face_2.jpg',
  'lib/assets/onboarding/face_3.jpg',
];

const double kPolaroidWidthShare = 0.64;
const double _kWellShare = 13 / 15;

// Decode buckets keep the prewarmed and the painted image one cache entry
const int _kDecodeStep = 64;
const int _kDecodeMax = 720;

// Past this the motion starts with whatever is ready
const Duration _kReadyTimeout = Duration(milliseconds: 1200);

// The shelf's hold, played once: the album jumps up, develops and fans. Only
// transforms and a flat wash change per frame, each print is a cached layer
class PolaroidStage extends StatefulWidget {
  const PolaroidStage({
    super.key,
    required this.width,
    this.onStart,
    this.onTick,
  });

  // As long as the wordmark takes to write, so both finish together
  static const Duration duration = Duration(milliseconds: 2540);
  static const double aspect = 300 / 372;

  final double width;
  // Fires once, as the motion starts
  final VoidCallback? onStart;
  // The stage's own time on every frame, for anything that moves with it
  final ValueChanged<Duration>? onTick;

  double get height => width / aspect;

  // Decodes the photos and faces at their painted size behind the route fade
  static void prewarm() {
    final view = ui.PlatformDispatcher.instance.implicitView;
    if (view == null) return;
    for (final image in [..._images(view.physicalSize.width), ..._faces]) {
      image.resolve(ImageConfiguration.empty).addListener(_keep);
    }
  }

  static final List<ImageProvider> _faces = [
    for (final f in _kFaces) AssetImage(f),
  ];

  // The cache holds the decoded image, this only keeps the stream open
  static final ImageStreamListener _keep = ImageStreamListener((_, __) {});

  static List<ImageProvider> _images(double physicalWidth) {
    final well = physicalWidth * kPolaroidWidthShare * _kWellShare;
    final bucket = (well / _kDecodeStep).ceil() * _kDecodeStep;
    final width = math.min(bucket, _kDecodeMax);
    return [
      for (final p in _kPhotos) ResizeImage(AssetImage(p), width: width),
    ];
  }

  @override
  State<PolaroidStage> createState() => _PolaroidStageState();
}

class _PolaroidStageState extends State<PolaroidStage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock =
      AnimationController(vsync: this, duration: PolaroidStage.duration)
        ..addListener(
            () => widget.onTick?.call(PolaroidStage.duration * _clock.value));

  late final Animation<double> _develop = CurvedAnimation(
      parent: _clock, curve: const Interval(0.08, 0.85, curve: Curves.easeOut));
  // Starts with the pen's first stroke, a little past its mark and back
  late final Animation<double> _jump = CurvedAnimation(
      parent: _clock,
      curve: const Interval(0, 0.34, curve: Curves.easeOutBack));
  late final Animation<double> _fanLeft = CurvedAnimation(
      parent: _clock, curve: const Interval(0.3, 1, curve: Curves.easeInOut));
  late final Animation<double> _fanRight = CurvedAnimation(
      parent: _clock, curve: const Interval(0.36, 1, curve: Curves.easeInOut));

  List<ImageProvider>? _images;
  final List<(ImageStream, ImageStreamListener)> _streams = [];
  Timer? _giveUp;
  bool _started = false;
  final Stopwatch _wait = Stopwatch();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_images != null) return;
    final media = MediaQuery.of(context);
    _images = PolaroidStage._images(media.size.width * media.devicePixelRatio);
    if (media.disableAnimations) {
      _clock.value = 1;
      _start('still');
      return;
    }
    final card = Size(widget.width, widget.height);
    final config = createLocalImageConfiguration(context);
    _wait.start();
    Future.wait([
      for (final image in [..._images!, ...PolaroidStage._faces])
        _decoded(image, config),
      PrintCard.warmShadow(Warm.printShadow, card, media.devicePixelRatio),
      PrintCard.warmShadow(Warm.printShadowBack, card, media.devicePixelRatio),
    ]).whenComplete(() => _start('ready'));
    _giveUp = Timer(_kReadyTimeout, () => _start('timeout'));
  }

  // Completes on decode or on failure, which leaves the well empty
  Future<void> _decoded(ImageProvider image, ImageConfiguration config) {
    final done = Completer<void>();
    final stream = image.resolve(config);
    final listener = ImageStreamListener(
      (_, __) => done.isCompleted ? null : done.complete(),
      onError: (_, __) => done.isCompleted ? null : done.complete(),
    );
    stream.addListener(listener);
    _streams.add((stream, listener));
    return done.future;
  }

  // Runs after the decodes and shadow bakes, so no frame decodes or blurs
  // live. endOfFrame also schedules the frame nothing else may be asking for
  Future<void> _start(String why) async {
    if (_started || !mounted) return;
    _started = true;
    _giveUp?.cancel();
    if (!_clock.isCompleted) {
      await SchedulerBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    Trace.event('polaroid.start',
        fields: {'why': why, 'ms': _wait.elapsedMilliseconds});
    widget.onStart?.call();
    if (_clock.isCompleted) {
      widget.onTick?.call(PolaroidStage.duration);
    } else {
      _clock.forward();
    }
  }

  @override
  void dispose() {
    _giveUp?.cancel();
    for (final (stream, listener) in _streams) {
      stream.removeListener(listener);
    }
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final images = _images!;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: _Jump(
        t: _jump,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            _Pose(
              t: _fanRight,
              out: const _Fan(12.5, Offset(0.058, -0.031), 0.975),
              child: _Print(image: images[2], shadow: Warm.printShadowBack),
            ),
            _Pose(
              t: _fanLeft,
              out: const _Fan(-12, Offset(-0.052, -0.047), 0.985),
              child: _Print(image: images[1], shadow: Warm.printShadowBack),
            ),
            Positioned.fill(
              child: RepaintBoundary(
                child: _Print(
                  image: images[0],
                  shadow: Warm.printShadow,
                  develop: _develop,
                  chin: const _Chin(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Fan {
  final double degrees;
  final Offset shift;
  final double scale;

  const _Fan(this.degrees, this.shift, this.scale);
}

// A print under the album, tucked at rest and fanned at one, as in AlbumPrint
class _Pose extends StatelessWidget {
  final Animation<double> t;
  final _Fan out;
  final Widget child;

  const _Pose({required this.t, required this.out, required this.child});

  static const double _tucked = 0.97;

  @override
  Widget build(BuildContext context) {
    final layer = RepaintBoundary(child: child);
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: t,
        child: layer,
        builder: (context, child) {
          final v = t.value;
          return FractionalTranslation(
            translation: out.shift * v,
            child: Transform.rotate(
              angle: out.degrees * v * math.pi / 180,
              child: Transform.scale(
                scale: ui.lerpDouble(_tucked, out.scale, v)!,
                child: child,
              ),
            ),
          );
        },
      ),
    );
  }
}

// The whole album rests a little low and small, then jumps up into place
class _Jump extends StatelessWidget {
  final Animation<double> t;
  final Widget child;

  const _Jump({required this.t, required this.child});

  static const double _drop = 0.09;
  static const double _rest = 0.97;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: t,
      child: child,
      builder: (context, child) => FractionalTranslation(
        translation: Offset(0, _drop * (1 - t.value)),
        child: Transform.scale(
          scale: ui.lerpDouble(_rest, 1, t.value)!,
          child: child,
        ),
      ),
    );
  }
}

class _Print extends StatelessWidget {
  final ImageProvider image;
  final List<BoxShadow> shadow;
  final Animation<double>? develop;
  final Widget? chin;

  const _Print({
    required this.image,
    required this.shadow,
    this.develop,
    this.chin,
  });

  @override
  Widget build(BuildContext context) {
    return PrintCard(
      shadow: shadow,
      develop: develop,
      chin: chin,
      well: Image(
        image: image,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}

// The same chin an album has on the shelf, for an album that is only shown
class _Chin extends StatelessWidget {
  const _Chin();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Picnic day',
                  style: Warm.cardTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 13),
            const _Faces(),
          ],
        ),
        const SizedBox(height: 5),
        Text('3 frames · 3 people',
            style: Warm.meta, maxLines: 1, overflow: TextOverflow.ellipsis),
      ],
    );
  }
}

// PrintFaces' overlap and paper ring, with the people's own photos
class _Faces extends StatelessWidget {
  const _Faces();

  static const double _size = 24;
  static const double _step = 17;

  @override
  Widget build(BuildContext context) {
    final faces = PolaroidStage._faces;
    return SizedBox(
      width: _size + (faces.length - 1) * _step,
      height: _size,
      child: Stack(
        children: [
          for (var i = 0; i < faces.length; i++)
            Positioned(
              left: i * _step,
              child: Container(
                width: _size,
                height: _size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Warm.wellEmpty,
                  boxShadow: const [
                    BoxShadow(color: Warm.paper, spreadRadius: 2),
                  ],
                  image: DecorationImage(image: faces[i], fit: BoxFit.cover),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
