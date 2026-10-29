import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:miuchio/data/models/album_summary.dart';
import 'package:miuchio/diagnostics/fx.dart';
import 'package:miuchio/diagnostics/perf_probe.dart';
import 'package:miuchio/ui/shelf/album_print.dart';
import 'package:miuchio/ui/shelf/print_style.dart';
import 'package:miuchio/ui/shelf/shelf_copy.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/print_card.dart';

const double _degrees = 3.141592653589793 / 180;

class _Pose {
  final double turns;
  final Offset shift;

  const _Pose(double degrees, this.shift) : turns = degrees / 360;
}

// Resting, the prints behind just show their edges; held, they fan out
const _restBack = [
  _Pose(-6, Offset(-0.035, 0.02)),
  _Pose(5, Offset(0.04, 0.03)),
];
const _fannedBack = [
  _Pose(-15, Offset(-0.14, -0.02)),
  _Pose(13, Offset(0.14, 0.01)),
];

// An album on the shelf as a small pile of prints: the cover on top, the
// next photos peeking out behind it, and a strip of tape holding it down.
// Its name and details sit under the pile rather than on a print's chin
class AlbumStack extends StatefulWidget {
  final String albumId;
  final String? title;
  final int mediaCount;
  final int unseen;
  final DateTime? lastActivity;
  final List<MemberPreview> members;
  final int totalMembers;
  final String? Function(MemberPreview) nameOf;
  final Widget? cover;
  // Photos behind the cover, once they have been loaded
  final List<Widget> behind;
  final Animation<double> develop;
  final bool small;
  final VoidCallback? onHold;
  final VoidCallback? onTap;
  // Global layout rect of the pile, untilted
  final void Function(Rect from)? onPeek;

  const AlbumStack({
    super.key,
    required this.albumId,
    required this.title,
    required this.mediaCount,
    required this.unseen,
    required this.lastActivity,
    required this.members,
    required this.totalMembers,
    required this.nameOf,
    required this.develop,
    this.small = false,
    this.cover,
    this.behind = const [],
    this.onHold,
    this.onTap,
    this.onPeek,
  });

  // The pile's height over its width, room for the tilted prints included
  static const double pileAspect = 0.98;
  static const double _largeText = 56;
  static const double _smallText = 48;

  // Lets the shelf plan rows before laying any card out
  static double heightFor(double width, {required bool small}) =>
      width * pileAspect + (small ? _smallText : _largeText);

  @override
  State<AlbumStack> createState() => _AlbumStackState();
}

class _AlbumStackState extends State<AlbumStack> {
  static const _peekAfter = Duration(milliseconds: 280);

  bool _fanned = false;
  Timer? _peek;

  void _setFanned(bool on) {
    if (_fanned == on) return;
    setState(() => _fanned = on);
  }

  void _release() {
    _peek?.cancel();
    _setFanned(false);
  }

  void _lift() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    _setFanned(false);
    widget.onPeek!(box.localToGlobal(Offset.zero) & box.size);
  }

  @override
  void dispose() {
    _peek?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    PerfProbe.count('stack');
    return RawGestureDetector(
      gestures: {
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
          TapGestureRecognizer.new,
          (r) => r.onTap = widget.onTap,
        ),
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
          () => LongPressGestureRecognizer(
              duration: const Duration(milliseconds: 180)),
          (r) {
            r.onLongPressStart = (_) {
              widget.onHold?.call();
              _setFanned(true);
              if (widget.onPeek != null) _peek = Timer(_peekAfter, _lift);
            };
            r.onLongPressEnd = (_) => _release();
            r.onLongPressCancel = _release;
          },
        ),
      },
      child: Semantics(
        button: true,
        label: widget.title,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: 1 / AlbumStack.pileAspect,
              child: LayoutBuilder(
                builder: (context, box) => _pile(box.maxWidth),
              ),
            ),
            SizedBox(
              height:
                  widget.small ? AlbumStack._smallText : AlbumStack._largeText,
              child: widget.small ? _smallText() : _largeText(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pile(double width) {
    final side = width * 0.84;
    final left = (width - side) / 2;
    final top = width * 0.07;
    final backs = Fx.noBacks ? 0 : fanFor(widget.mediaCount);
    final poses = _fanned ? _fannedBack : _restBack;
    final tilt =
        Fx.noTilt ? 0.0 : tiltFor(widget.albumId, small: widget.small) * 0.6;

    Widget at(Widget child) => Positioned(
        left: left, top: top, width: side, height: side, child: child);

    return Transform.rotate(
      angle: tilt * _degrees,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Farthest first, so the nearer print lands on top of it
          for (var i = backs - 1; i >= 0; i--)
            at(AnimatedSlide(
              offset: poses[i].shift,
              duration: Warm.springSoft,
              curve: Warm.easeSoft,
              child: AnimatedRotation(
                turns: poses[i].turns,
                duration: Warm.springSoft,
                curve: Warm.easeSoft,
                child: _Print(
                  side: side,
                  back: true,
                  child: i < widget.behind.length ? widget.behind[i] : null,
                ),
              ),
            )),
          at(_Print(
            side: side,
            develop:
                widget.cover != null && !Fx.noDevelop ? widget.develop : null,
            child: widget.cover,
          )),
          Positioned(
            left: left + side * 0.32,
            top: top - side * 0.04,
            width: side * 0.36,
            height: side * 0.09,
            // Each album keeps its own tape colour, the way it keeps its tilt
            child: _Tape(
                color: Warm.orbPalette[fnv1a32('tape:${widget.albumId}') %
                    Warm.orbPalette.length]),
          ),
          if (widget.unseen > 0)
            Positioned(
              right: left - side * 0.07,
              top: top - side * 0.07,
              child: _NewSticker(
                count: widget.unseen,
                size: widget.small ? 38 : 50,
              ),
            ),
        ],
      ),
    );
  }

  String get _meta {
    final n = widget.mediaCount;
    final photos = n == 0 ? 'No photos yet' : '$n photo${n == 1 ? '' : 's'}';
    final time = relativeTime(widget.lastActivity);
    return time == null ? photos : '$photos · $time';
  }

  Widget _largeText() => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.title ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Warm.cardTitle.copyWith(height: 1.25)),
                  const SizedBox(height: 3),
                  Text(_meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Warm.meta.copyWith(height: 1.3)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: PrintFaces(
                albumId: widget.albumId,
                members: widget.members,
                total: widget.totalMembers,
                nameOf: widget.nameOf,
                ring: Warm.ground,
              ),
            ),
          ],
        ),
      );

  Widget _smallText() => Padding(
        padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Warm.cardTitle.copyWith(fontSize: 14.5, height: 1.25)),
            const SizedBox(height: 2),
            Text(_meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Warm.meta.copyWith(fontSize: 12, height: 1.3)),
          ],
        ),
      );
}

// A square print with a thin paper border
class _Print extends StatelessWidget {
  final double side;
  final Widget? child;
  final Animation<double>? develop;
  final bool back;

  const _Print({
    required this.side,
    this.child,
    this.develop,
    this.back = false,
  });

  @override
  Widget build(BuildContext context) {
    final border = side * 0.045;
    return Container(
      padding: EdgeInsets.all(border),
      decoration: BoxDecoration(
        color: Warm.paper,
        borderRadius: BorderRadius.circular(5),
        boxShadow: Fx.noShadow
            ? null
            : [
                BoxShadow(
                    color: Warm.shadow(back ? 0.06 : 0.08),
                    blurRadius: 2,
                    offset: const Offset(0, 1)),
                BoxShadow(
                    color: Warm.shadow(back ? 0.05 : 0.09),
                    blurRadius: back ? 8 : 14,
                    offset: Offset(0, back ? 3 : 7)),
              ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: child == null ? null : Warm.wellEmpty,
                gradient: child == null ? Warm.blankWellFill : null,
              ),
            ),
            if (child != null) child!,
            if (develop != null) Emulsion(develop: develop!),
          ],
        ),
      ),
    );
  }
}

// Washi tape: translucent, a touch crooked, with a faint woven stripe
class _Tape extends StatelessWidget {
  final Color color;

  const _Tape({required this.color});

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: -3 * _degrees,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(1.5),
          // Deeper than the pastel it comes from, so it reads on paper
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.lerp(color, Warm.cta, 0.12)!.withValues(alpha: 0.95),
              Color.lerp(color, Warm.cta, 0.04)!.withValues(alpha: 0.86),
              Color.lerp(color, Warm.cta, 0.12)!.withValues(alpha: 0.95),
            ],
          ),
          boxShadow: [
            BoxShadow(
                color: Warm.shadow(0.08),
                blurRadius: 1.5,
                offset: const Offset(0, 0.5)),
          ],
        ),
        child: const CustomPaint(painter: _Weave()),
      ),
    );
  }
}

// Fine diagonal threads, the paper grain of real washi
class _Weave extends CustomPainter {
  const _Weave();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x1FFFFFFF)
      ..strokeWidth = 1;
    canvas.clipRect(Offset.zero & size);
    for (var x = -size.height; x < size.width; x += 4) {
      canvas.drawLine(
          Offset(x, size.height), Offset(x + size.height, 0), paint);
    }
  }

  @override
  bool shouldRepaint(_Weave old) => false;
}

// New photos, as a round sticker slapped on the corner of the pile
class _NewSticker extends StatelessWidget {
  final int count;
  final double size;

  const _NewSticker({required this.count, required this.size});

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: 9 * _degrees,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Warm.warn,
          border: Border.all(color: Warm.paper, width: size * 0.06),
          boxShadow: [
            BoxShadow(
                color: Warm.shadow(0.16),
                blurRadius: 6,
                offset: const Offset(0, 3)),
          ],
        ),
        child: Semantics(
          label: '$count new',
          excludeSemantics: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(count > 99 ? '99+' : '$count',
                  style: Warm.cardTitle.copyWith(
                      color: Warm.ctaInk,
                      fontSize: size * 0.32,
                      height: 1,
                      fontWeight: FontWeight.w700)),
              Text('new',
                  style: Warm.meta.copyWith(
                      color: Warm.ctaInk,
                      fontSize: size * 0.2,
                      height: 1.1,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}
