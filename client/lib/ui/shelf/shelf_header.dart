part of 'shelf_screen.dart';

class _Header extends StatelessWidget {
  final ShelfView view;
  final ValueChanged<ShelfView> onSetView;
  final VoidCallback? onOpenProfile;
  final bool docked;

  const _Header(
      {required this.view,
      required this.onSetView,
      required this.onOpenProfile,
      required this.docked});

  // Docked, the title lines up with the other tabs' titles
  static double topFor(bool docked) => docked ? 37 : 21;

  @override
  Widget build(BuildContext context) {
    final name = context.select((AppState s) => s.profileName);
    final initial = name.trim().isEmpty ? '' : name.trim()[0].toUpperCase();
    final photo = context.select<OwnAvatarStore?, Uint8List?>(
        (o) => o?.state == OwnAvatarState.set ? o?.jpeg : null);

    return Padding(
      // Keep the 48px target centred on the previous 38px header row
      padding:
          EdgeInsets.fromLTRB(Warm.pagePad, topFor(docked), Warm.pagePad, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (docked)
            Text('Albums', style: Warm.pageTitle)
          else
            GestureDetector(
              onTap: onOpenProfile,
              child: FaceCircle(
                size: 34,
                color: photo == null ? faceHue('', name) : Colors.transparent,
                photo: photo,
                child: Text(initial, style: Warm.avatarInitial),
              ),
            ),
          _ViewPicker(view: view, onSelect: onSetView),
        ],
      ),
    );
  }
}

class _ViewPicker extends StatefulWidget {
  final ShelfView view;
  final ValueChanged<ShelfView> onSelect;

  const _ViewPicker({required this.view, required this.onSelect});

  @override
  State<_ViewPicker> createState() => _ViewPickerState();
}

class _ViewPickerState extends State<_ViewPicker>
    with TickerProviderStateMixin {
  late final AnimationController _split = AnimationController(
    vsync: this,
    duration: Warm.springSoft,
    value: _compact ? 1 : 0,
  );
  late final AnimationController _said = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  // Fades in, holds, fades out
  late final Animation<double> _saidOpacity = TweenSequence([
    TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 15),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 55),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 30),
  ]).animate(_said);
  bool _pressed = false;

  bool get _compact => widget.view == ShelfView.compact;

  @override
  void didUpdateWidget(covariant _ViewPicker old) {
    super.didUpdateWidget(old);
    if (old.view != widget.view) {
      _split.animateTo(_compact ? 1 : 0, curve: Warm.easeSoft);
    }
  }

  @override
  void dispose() {
    _split.dispose();
    _said.dispose();
    super.dispose();
  }

  void _toggle() {
    widget.onSelect(_compact ? ShelfView.stacked : ShelfView.compact);
    _said.forward(from: 0);
  }

  void _press(bool down) => setState(() => _pressed = down);

  @override
  Widget build(BuildContext context) {
    final name = _compact ? 'Compact' : 'Stacked';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _said,
          builder: (_, child) => Opacity(
            opacity: _saidOpacity.value,
            child: Transform.translate(
              offset: Offset(6 * (1 - (_said.value / 0.15).clamp(0.0, 1.0)), 0),
              child: child,
            ),
          ),
          child: Text(name,
              key: const ValueKey('view-said'), style: Warm.viewSaid),
        ),
        Semantics(
          button: true,
          label: 'Shelf view: $name',
          excludeSemantics: true,
          child: GestureDetector(
            key: const ValueKey('view-trigger'),
            behavior: HitTestBehavior.opaque,
            onTap: _toggle,
            onTapDown: (_) => _press(true),
            onTapUp: (_) => _press(false),
            onTapCancel: () => _press(false),
            // 48 to tap around the avatar sized 38
            child: SizedBox(
              width: 48,
              height: 48,
              child: Align(
                alignment: Alignment.centerRight,
                child: AnimatedScale(
                  scale: _pressed ? 0.94 : 1,
                  duration: Warm.quick,
                  curve: Warm.easeOut,
                  child: CustomPaint(
                    size: const Size.square(18),
                    painter: _LayoutGlyph(_split),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// The shelf in miniature: Compact splits the lower print in two
class _LayoutGlyph extends CustomPainter {
  final Animation<double> split;

  _LayoutGlyph(this.split) : super(repaint: split);

  @override
  void paint(Canvas canvas, Size size) {
    final t = split.value;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = Warm.ink;
    RRect r(double x, double y, double w) => RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, w, 5.6), const Radius.circular(1.5));
    final w = 12 - 6.8 * t;

    canvas.drawRRect(r(3, 2.6, 12), paint);
    canvas.drawRRect(r(3, 10, w), paint);
    canvas.drawRRect(
      r(3 + 6.8 * t, 10, w),
      paint..color = Warm.ink.withValues(alpha: t),
    );
  }

  @override
  bool shouldRepaint(_LayoutGlyph old) => old.split != split;
}

class _Say extends StatelessWidget {
  final Headline headline;
  final bool docked;

  const _Say({required this.headline, this.docked = false});

  static const double top = 20;
  static const double gap = 9;
  static const double dockedTop = 4;

  // Under the Albums title the headline reads as one easy sentence:
  // "Two new frames in Road trip." rather than a heading and a fragment
  static String sentence(Headline h) {
    if (h.sub.isEmpty) return h.title;
    final first = h.sub[0];
    final continues = first != first.toUpperCase();
    return continues
        ? '${h.title.replaceFirst(RegExp(r'\.$'), '')} ${h.sub}'
        : '${h.title} ${h.sub}';
  }

  @override
  Widget build(BuildContext context) {
    if (docked) {
      return Padding(
        padding:
            const EdgeInsets.fromLTRB(Warm.pagePad, dockedTop, Warm.pagePad, 0),
        child: AnimatedSwitcher(
          duration: Warm.crossfade,
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.topLeft,
            children: [...previous, if (current != null) current],
          ),
          child: Text(sentence(headline),
              key: ValueKey(sentence(headline)), style: Warm.sub),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(Warm.pagePad, top, Warm.pagePad, 0),
      child: AnimatedSwitcher(
        duration: Warm.crossfade,
        switchInCurve: Warm.easeSoft,
        switchOutCurve: const FlippedCurve(Warm.easeSoft),
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topLeft,
          children: [...previous, if (current != null) current],
        ),
        child: Column(
          key: ValueKey('${headline.title}|${headline.sub}'),
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(headline.title, style: Warm.h1),
            if (headline.sub.isNotEmpty) ...[
              const SizedBox(height: gap),
              Text(headline.sub, style: Warm.sub),
            ],
          ],
        ),
      ),
    );
  }
}
