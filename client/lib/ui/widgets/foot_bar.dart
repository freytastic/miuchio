import 'package:flutter/material.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';

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

// The one place the make button lives, on every screen that has one: bottom
// center, just above the home indicator. Screens only say what it does, so it
// never moves as you go from Home into an album. Must sit in a Stack that
// reaches the bottom of the screen
class MakeSpot extends StatelessWidget {
  static const double size = 52;
  // Its bottom edge above the bottom inset
  static const double lift = 14;
  // Its top edge above the bottom inset, for anything stacked over it
  static const double top = lift + size;

  final VoidCallback? onTap;
  final String tooltip;
  final String? hint;

  const MakeSpot(
      {super.key, required this.onTap, required this.tooltip, this.hint});

  @override
  Widget build(BuildContext context) => Positioned(
        left: 0,
        right: 0,
        bottom: lift + MediaQuery.paddingOf(context).bottom,
        child: Center(
          child: Semantics(
            button: true,
            hint: hint,
            child: MakeButton(onTap: onTap, tooltip: tooltip, size: size),
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
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _pressed ? Warm.ctaPressed : Warm.cta,
            shape: BoxShape.circle,
            boxShadow: Warm.ctaShadow,
          ),
          child: SizedBox.square(
            dimension: widget.size,
            child: Icon(Icons.add_rounded,
                size: widget.size * 0.36,
                color: widget.onTap == null
                    ? Warm.ctaInk.withValues(alpha: 0.45)
                    : Warm.ctaInk),
          ),
        ),
      ),
    );
    final label = widget.tooltip;
    return label == null ? button : Tooltip(message: label, child: button);
  }
}
