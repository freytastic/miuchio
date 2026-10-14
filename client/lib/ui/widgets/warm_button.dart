import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/pressable_scale.dart';

class WarmButton extends StatefulWidget {
  final String label;
  final VoidCallback? onTap;
  final bool busy;
  final bool small;
  final double? width;

  const WarmButton({
    super.key,
    required this.label,
    required this.onTap,
    this.busy = false,
    this.small = false,
    this.width,
  });

  @override
  State<WarmButton> createState() => _WarmButtonState();
}

class _WarmButtonState extends State<WarmButton> {
  bool _pressed = false;

  bool get _enabled => widget.onTap != null && !widget.busy;

  void _press(bool down) {
    if (_pressed != down) setState(() => _pressed = down);
  }

  @override
  Widget build(BuildContext context) {
    final height = widget.small ? 40.0 : Warm.ctaHeight;
    final radius = height / 2;
    final enabled = _enabled;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _press(true) : null,
      onTapCancel: enabled ? () => _press(false) : null,
      onTapUp: enabled ? (_) => _press(false) : null,
      onTap: enabled
          ? () {
              HapticFeedback.lightImpact();
              widget.onTap!();
            }
          : null,
      child: AnimatedOpacity(
        opacity: enabled || widget.busy ? 1 : 0.42,
        duration: Warm.quick,
        child: AnimatedScale(
          scale: _pressed ? 0.965 : 1,
          duration: Warm.quick,
          curve: Warm.easeOut,
          child: Container(
            width: widget.width,
            height: height,
            padding: EdgeInsets.symmetric(horizontal: widget.small ? 18 : 24),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _pressed ? Warm.ctaPressed : Warm.cta,
              borderRadius: BorderRadius.circular(radius),
              boxShadow: enabled ? Warm.ctaShadow : Warm.ctaShadowIdle,
            ),
            child: widget.busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Warm.ctaInk),
                  )
                : AnimatedSwitcher(
                    duration: Warm.quick,
                    child: Text(
                      widget.label,
                      key: ValueKey(widget.label),
                      maxLines: 1,
                      style: widget.small
                          ? Warm.ctaLabel.copyWith(fontSize: 13.5)
                          : Warm.ctaLabel,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class WarmTextButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final Color color;

  const WarmTextButton({
    super.key,
    required this.label,
    required this.onTap,
    this.color = Warm.inkSoft,
  });

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: Warm.textAction
              .copyWith(color: onTap == null ? Warm.inkFaint : color),
        ),
      ),
    );
  }
}

class WarmBack extends StatelessWidget {
  final VoidCallback? onTap;

  const WarmBack({super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Back',
      child: PressableScale(
        onTap: onTap ?? () => Navigator.of(context).maybePop(),
        child: const SizedBox(
          width: 40,
          height: 40,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Icon(Icons.chevron_left_rounded, size: 28, color: Warm.ink),
          ),
        ),
      ),
    );
  }
}
