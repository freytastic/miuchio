import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:miuchio/data/models/album_model.dart';
import 'package:miuchio/data/models/album_summary.dart';
import 'package:provider/provider.dart';
import 'package:miuchio/ui/album/album_copy.dart';
import 'package:miuchio/ui/album/album_menu.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/shelf/album_print.dart';
import 'package:miuchio/ui/shelf/shelf_copy.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/blur_scrim.dart';
import 'package:miuchio/ui/widgets/peek_route.dart';
import 'package:miuchio/ui/widgets/pressable_scale.dart';

typedef PeekPrint = Widget Function({required bool fanned});

const double _degrees = math.pi / 180;

enum ShelfPeekAction { open, people, rename }

class ShelfPeek extends StatefulWidget {
  final AlbumModel album;
  final Rect from;
  final double tilt;
  final PeekPrint print;
  final Animation<double> entry;

  const ShelfPeek({
    super.key,
    required this.album,
    required this.from,
    required this.tilt,
    required this.print,
    this.entry = kAlwaysCompleteAnimation,
  });

  // Resolves to the action picked, or null when dismissed
  static PeekRoute<ShelfPeekAction> route({
    required AlbumModel album,
    required Rect from,
    required double tilt,
    required PeekPrint print,
  }) =>
      PeekRoute<ShelfPeekAction>(
        transitionDuration: const Duration(milliseconds: 520),
        reverseTransitionDuration: Warm.springSnappy,
        builder: (_, a, __) => ShelfPeek(
          album: album,
          from: from,
          tilt: tilt,
          print: print,
          entry: a,
        ),
      );

  @override
  State<ShelfPeek> createState() => _ShelfPeekState();
}

class _ShelfPeekState extends State<ShelfPeek> {
  late final CurvedAnimation _lift = CurvedAnimation(
    parent: widget.entry,
    curve: Warm.easeSoft,
    reverseCurve: Curves.easeInOutCubic,
  );
  late final CurvedAnimation _menu = CurvedAnimation(
    parent: widget.entry,
    curve: const Interval(0.15, 1, curve: Warm.easeOut),
  );
  bool _fanned = false;
  bool _info = false;
  bool _leaving = false;
  Rect _target = Rect.zero;

  @override
  void initState() {
    super.initState();
    // Fan after the first frame so the backs animate out
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _fanned = true);
    });
  }

  @override
  void dispose() {
    _lift.dispose();
    _menu.dispose();
    super.dispose();
  }

  // This route leaves at once, so the print tucks away in an overlay entry
  // that stays above the screen being opened
  void _open() => _leave(ShelfPeekAction.open);

  void _leave(ShelfPeekAction action) {
    late final OverlayEntry tuck;
    tuck = OverlayEntry(
      builder: (_) => _Tuck(
        rect: _target,
        print: widget.print(fanned: true),
        onDone: tuck.remove,
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(tuck);
    setState(() => _leaving = true);
    Navigator.of(context).pop(action);
  }

  Rect _targetFor(Size size, EdgeInsets pad) {
    final w = math.min(292.0, size.width - 76);
    final h = w * 372 / 300;
    final top = math.max(pad.top + 24, (size.height - (h + 22 + 214)) / 2 - 8);
    return Rect.fromLTWH((size.width - w) / 2, top, w, h);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    _target = _targetFor(size, MediaQuery.paddingOf(context));
    final menuWidth = math.min(270.0, size.width - 76);

    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && result == null) setState(() => _fanned = false);
      },
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            Positioned.fill(
              child: BlurScrim(
                progress: _lift,
                color: Warm.shelfPeekScrim,
                sigma: Warm.shelfPeekBlur,
                onTap: () => Navigator.of(context).maybePop(),
              ),
            ),
            if (!_leaving)
              Positioned.fromRect(
                rect: _target,
                child: AnimatedBuilder(
                  animation: _lift,
                  builder: (_, child) {
                    final t = _lift.value;
                    return Transform.translate(
                      offset: (widget.from.center - _target.center) * (1 - t),
                      child: Transform.rotate(
                        angle: widget.tilt * (1 - t) * _degrees,
                        child: Transform.scale(
                          scale: lerpDouble(
                              widget.from.width / _target.width, 1, t),
                          child: child,
                        ),
                      ),
                    );
                  },
                  child: GestureDetector(
                    onTap: _open,
                    child: widget.print(fanned: _fanned),
                  ),
                ),
              ),
            Positioned(
              top: _target.bottom + 22,
              left: (size.width - menuWidth) / 2,
              width: menuWidth,
              child: FadeTransition(
                opacity: _menu,
                child: ScaleTransition(
                  alignment: Alignment.topCenter,
                  scale: Tween<double>(begin: 0.96, end: 1).animate(_menu),
                  child: AnimatedSwitcher(
                    duration: Warm.quick,
                    child: _info ? _facts() : _actions(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actions() => MenuCard(
        key: const ValueKey('shelf-peek-menu'),
        children: [
          MenuItem(
            label: AlbumCopy.openAlbum,
            icon: Icons.arrow_outward_rounded,
            onTap: _open,
          ),
          MenuItem(
            label: AlbumCopy.people,
            onTap: () => _leave(ShelfPeekAction.people),
          ),
          const MenuSeparator(),
          if (widget.album.myRole == 'admin')
            MenuItem(
              label: AlbumCopy.renameAlbum,
              // Stays on the shelf, so the print flies back instead of tucking
              onTap: () => Navigator.of(context).pop(ShelfPeekAction.rename),
            ),
          MenuItem(
            label: AlbumCopy.albumInfo,
            icon: Icons.info_outline_rounded,
            onTap: () => setState(() => _info = true),
          ),
        ],
      );

  // The face keeps your own name and colour; only the sentence says "You"
  String? _nameOf(BuildContext context, MemberPreview m) {
    final a = widget.album;
    final state = Provider.of<AppState?>(context, listen: false);
    if (m.memberToken == a.memberToken) return state?.profileName;
    return state?.memberDisplayName(a.id, m.memberToken);
  }

  // "You and Bob", "You, Bob and 3 others": the names are the count
  String _whoCanSee(BuildContext context) {
    final a = widget.album;
    final names = [
      for (final m in a.memberPreviews)
        m.memberToken == a.memberToken
            ? AlbumCopy.you
            : _nameOf(context, m) ?? 'Someone',
    ]..sort((x, y) => x == AlbumCopy.you ? -1 : (y == AlbumCopy.you ? 1 : 0));
    final shown = names.take(2).toList();
    final rest = math.max(a.activeMemberCount, names.length) - shown.length;
    if (rest > 0) {
      return '${shown.join(', ')} and $rest other${rest == 1 ? '' : 's'}';
    }
    if (shown.length == 1) return '${shown.single} only';
    return shown.join(' and ');
  }

  Widget _facts() {
    final a = widget.album;
    return MenuCard(
      key: const ValueKey('shelf-peek-info'),
      children: [
        PressableScale(
          onTap: () => setState(() => _info = false),
          child: const Padding(
            padding: EdgeInsets.fromLTRB(4, 9, 12, 9),
            child: Row(
              children: [
                Icon(Icons.chevron_left_rounded, size: 20, color: Warm.inkSoft),
                SizedBox(width: 2),
                Text(
                  AlbumCopy.albumInfo,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: Warm.ink,
                  ),
                ),
              ],
            ),
          ),
        ),
        // Numbers lead with quiet units, rather than "Photos: 7" rows
        Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: Warm.inkGhost)),
          ),
          child: Row(
            children: [
              _Count(
                  value: a.mediaCount,
                  unit: a.mediaCount == 1 ? 'photo' : 'photos'),
            ],
          ),
        ),
        // Who can see it, as faces and names, so the count is never a bare
        // number to take on trust
        if (a.memberPreviews.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Row(
              children: [
                PrintFaces(
                  albumId: a.id,
                  members: a.memberPreviews,
                  total: a.activeMemberCount,
                  nameOf: (m) => _nameOf(context, m),
                  ring: Warm.paper,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _whoCanSee(context),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: Warm.inkSoft),
                  ),
                ),
              ],
            ),
          ),
        if (_lastPhoto(a.mediaCount, a.latestActivityAt) case final line?)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Text(
              line,
              style: const TextStyle(fontSize: 13, color: Warm.inkSoft),
            ),
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(Icons.lock_outline_rounded,
                    size: 13, color: Warm.inkFaint),
              ),
              SizedBox(width: 7),
              Expanded(
                child: Text(
                  AlbumCopy.infoKey,
                  style: TextStyle(
                      fontSize: 12, height: 1.45, color: Warm.inkSoft),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// "Last photo yesterday" reads as one fact; a label and value split it in two
// A listing without a date says nothing rather than "no photos"
String? _lastPhoto(int count, DateTime? at) {
  if (count == 0) return AlbumCopy.noPhotosYet;
  final when = relativeTime(at);
  return when == null ? null : 'Last photo $when';
}

class _Count extends StatelessWidget {
  final int value;
  final String unit;

  const _Count({required this.value, required this.unit});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$value $unit',
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            '$value',
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.5,
              color: Warm.ink,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 5),
          Text(unit, style: const TextStyle(fontSize: 13, color: Warm.inkSoft)),
        ],
      ),
    );
  }
}

// Shrinks into the lower left, then accelerates off the edge
class _Tuck extends StatefulWidget {
  final Rect rect;
  final Widget print;
  final VoidCallback onDone;

  const _Tuck({required this.rect, required this.print, required this.onDone});

  @override
  State<_Tuck> createState() => _TuckState();
}

class _TuckState extends State<_Tuck> with SingleTickerProviderStateMixin {
  static const _small = 0.3;
  static const _split = 0.52;
  static const _out = Cubic(0.55, 0, 0.85, 0.35);

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 720),
  )..forward().whenComplete(widget.onDone);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    final from = widget.rect.center;
    final half = widget.rect.width * _small / 2;
    final corner = Offset(30 + half, height - 130);
    final gone = Offset(-half * 1.6, height - 110);

    return IgnorePointer(
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            Positioned.fromRect(
              rect: widget.rect,
              child: AnimatedBuilder(
                animation: _c,
                builder: (_, child) {
                  final t = _c.value;
                  final settle = t < _split;
                  final u = settle
                      ? Warm.easeOut.transform(t / _split)
                      : _out.transform((t - _split) / (1 - _split));
                  final at = settle
                      ? Offset.lerp(from, corner, u)!
                      : Offset.lerp(corner, gone, u)!;
                  return Transform.translate(
                    offset: at - from,
                    child: Transform.rotate(
                      angle: (settle ? -4 * u : -4 - 7 * u) * _degrees,
                      child: Transform.scale(
                        scale: settle
                            ? lerpDouble(1, _small, u)
                            : _small * (1 - 0.08 * u),
                        child: child,
                      ),
                    ),
                  );
                },
                child: widget.print,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
