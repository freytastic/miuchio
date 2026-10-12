import 'package:flutter/material.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/baked_paint.dart';
import 'package:miuchio/ui/widgets/warm_button.dart';

class FootScrim extends StatelessWidget {
  final double height;

  const FootScrim({super.key, required this.height});

  static const _fade = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0x00F6F3EE),
      Color(0x80F6F3EE),
      Color(0xE6F6F3EE),
      Warm.ground,
      Warm.ground,
    ],
    stops: [0, 0.26, 0.5, 0.66, 1],
  );

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: const DecoratedBox(
            decoration: BoxDecoration(gradient: _fade),
          ),
        ),
      );
}

class MakeButton extends StatefulWidget {
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;

  const MakeButton(
      {super.key, required this.onTap, this.tooltip, this.size = 58});

  @override
  State<MakeButton> createState() => _MakeButtonState();
}

class _MakeButtonState extends State<MakeButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final button = GestureDetector(
      onTapDown:
          widget.onTap == null ? null : (_) => setState(() => _pressed = true),
      onTapUp: widget.onTap == null
          ? null
          : (_) {
              setState(() => _pressed = false);
              widget.onTap!();
            },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1,
        duration: Warm.quick,
        curve: Warm.easeOut,
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: AnimatedOpacity(
                  opacity: _pressed ? 1 : 0.45,
                  duration: Warm.quick,
                  child: const _MakeGlow(),
                ),
              ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: Warm.ctaShadow,
                  ),
                ),
              ),
              DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: Warm.ctaFill,
                  shape: BoxShape.circle,
                ),
                child: SizedBox.square(dimension: widget.size),
              ),
              Positioned.fill(
                  child: WarmGlow(lit: _pressed, radius: widget.size / 2)),
              Positioned(
                top: 1,
                left: 1,
                right: 1,
                height: widget.size * 0.4,
                child: IgnorePointer(
                    child: WarmSheen(radius: widget.size / 2 - 1)),
              ),
              Icon(Icons.add_rounded,
                  size: widget.size * 0.36,
                  color: widget.onTap == null
                      ? Warm.ctaInk.withValues(alpha: 0.45)
                      : Warm.ctaInk),
            ],
          ),
        ),
      ),
    );
    final label = widget.tooltip;
    return label == null ? button : Tooltip(message: label, child: button);
  }
}

class _MakeGlow extends StatelessWidget {
  const _MakeGlow();

  // Allow for the circle overflow plus three blur sigmas
  @override
  Widget build(BuildContext context) => const BakedPaint(
        id: 'make-glow',
        overflow: EdgeInsets.all(44),
        maxScale: 2,
        painter: _paintGlow,
      );
}

void _paintGlow(Canvas canvas, Size size) {
  final centre = size.center(Offset.zero);
  final radius = size.width * 0.84;
  final paint = Paint()
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8)
    ..shader = RadialGradient(
      colors: [
        Warm.orbPeach.withValues(alpha: 0.6),
        Warm.orbBlush.withValues(alpha: 0.3),
        Warm.orbPeach.withValues(alpha: 0),
      ],
      stops: const [0, 0.45, 0.72],
    ).createShader(Rect.fromCircle(center: centre, radius: radius));
  canvas.drawCircle(centre, radius, paint);
}
