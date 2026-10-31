part of 'shelf_screen.dart';

class _Grid extends StatelessWidget {
  final List<ShelfSlot<AlbumModel>> plan;
  final ShelfView view;
  // Width fraction for the first print, below 1 only in compact view
  final double leadScale;
  final int Function(AlbumModel) unseenFor;
  final DevelopStore develop;
  final Set<String> entered;
  final void Function(AlbumModel) onOpenAlbum;

  static const double pairGap = 12;
  static const double printAspect = 372 / 300;
  static double topFor(ShelfView v) => v == ShelfView.compact ? 24 : 32;
  static double rowGapFor(ShelfView v) => v == ShelfView.compact ? 16 : 30;

  const _Grid({
    required this.plan,
    required this.view,
    this.leadScale = 1,
    required this.unseenFor,
    required this.develop,
    required this.entered,
    required this.onOpenAlbum,
  });

  List<List<ShelfSlot<AlbumModel>>> _rows() {
    final rows = <List<ShelfSlot<AlbumModel>>>[];
    for (var i = 0; i < plan.length; i++) {
      final slot = plan[i];
      if (slot.size == PrintSize.large) {
        rows.add([slot]);
        continue;
      }
      final next = i + 1 < plan.length ? plan[i + 1] : null;
      if (next != null && next.size == PrintSize.small) {
        rows.add([slot, next]);
        i++;
      } else {
        rows.add([slot]);
      }
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final rowGap = rowGapFor(view);
    final rows = _rows();
    var seen = 0;
    final starts = [for (final r in rows) (seen += r.length) - r.length];

    return SliverPadding(
      padding: EdgeInsets.fromLTRB(Warm.pagePad, topFor(view), Warm.pagePad, 0),
      sliver: SliverList.builder(
        itemCount: rows.length,
        itemBuilder: (context, r) {
          final row = rows[r];
          final gap = r > 0 ? rowGap : 0.0;
          final Widget content = row.first.size == PrintSize.large
              ? r == 0 && leadScale < 1
                  ? Center(
                      child: FractionallySizedBox(
                        widthFactor: leadScale,
                        child: _card(row.first, starts[r]),
                      ),
                    )
                  : _card(row.first, starts[r])
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _card(row.first, starts[r])),
                    const SizedBox(width: pairGap),
                    Expanded(
                      child: row.length > 1
                          ? _card(row[1], starts[r] + 1)
                          : const SizedBox.shrink(),
                    ),
                  ],
                );
          return Padding(
            padding: EdgeInsets.only(top: gap),
            child: content,
          );
        },
      ),
    );
  }

  Widget _card(ShelfSlot<AlbumModel> slot, int index) {
    final a = slot.album;
    return _ShelfCard(
      key: ValueKey(a.id),
      album: a,
      size: slot.size,
      index: index,
      unseen: unseenFor(a),
      develop: develop.sync(a.id, unseenFor(a)),
      hasEntered: entered.contains(a.id),
      onEntered: () => entered.add(a.id),
      onTap: () => onOpenAlbum(a),
    );
  }
}

class _ShelfCard extends StatefulWidget {
  final AlbumModel album;
  final PrintSize size;
  final int index;
  final int unseen;
  final Animation<double> develop;
  final bool hasEntered;
  final VoidCallback onEntered;
  final VoidCallback onTap;

  const _ShelfCard({
    super.key,
    required this.album,
    required this.size,
    required this.index,
    required this.unseen,
    required this.develop,
    required this.hasEntered,
    required this.onEntered,
    required this.onTap,
  });

  @override
  State<_ShelfCard> createState() => _ShelfCardState();
}

class _ShelfCardState extends State<_ShelfCard> {
  late bool _entered = widget.hasEntered;
  Timer? _enter;
  bool _lifted = false;

  ShelfCovers? get _covers {
    try {
      return context.read<ShelfCovers>();
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    if (!_entered) {
      final delay =
          Warm.cardStaggerOffset + Warm.cardStagger * (widget.index % 6);
      _enter = Timer(delay, () {
        if (!mounted) return;
        widget.onEntered();
        setState(() => _entered = true);
        PerfProbe.window('shelf.entry', Warm.springSoft);
      });
    }
    _requestCover();
  }

  @override
  void didUpdateWidget(covariant _ShelfCard old) {
    super.didUpdateWidget(old);
    if (old.album.previewMedia.length != widget.album.previewMedia.length ||
        _firstPreviewId(old.album) != _firstPreviewId(widget.album)) {
      _requestCover();
    }
  }

  static String? _firstPreviewId(AlbumModel a) =>
      a.previewMedia.isEmpty ? null : a.previewMedia.first.mediaId;

  void _requestCover() {
    if (widget.album.previewMedia.isEmpty) return;
    _covers?.ensureCover(widget.album.id, widget.album.previewMedia);
  }

  @override
  void dispose() {
    _enter?.cancel();
    super.dispose();
  }

  Widget? _image(int slot) {
    final bytes = printPhoto(context, widget.album, slot);
    if (bytes == null) return null;
    return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
  }

  Widget _print({
    required PrintSize size,
    bool fanned = false,
    bool tilted = true,
    VoidCallback? onHold,
    VoidCallback? onTap,
    void Function(Rect)? onPeek,
  }) {
    final state = context.read<AppState>();
    return AlbumPrint(
      albumId: widget.album.id,
      title: state.albumDisplayName(widget.album.id),
      mediaCount: widget.album.mediaCount,
      unseen: widget.unseen,
      lastActivity: widget.album.latestActivityAt,
      members: widget.album.memberPreviews,
      totalMembers: widget.album.activeMemberCount,
      nameOf: (m) => state.memberDisplayName(widget.album.id, m.memberToken),
      develop: widget.develop,
      size: size,
      cover: _image(0),
      behind: [_image(1), _image(2)].nonNulls.toList(),
      fanned: fanned,
      tilted: tilted,
      onHold: onHold,
      onTap: onTap,
      onPeek: onPeek,
    );
  }

  Future<void> _peek(Rect from) async {
    HapticFeedback.selectionClick();
    final route = ShelfPeek.route(
      album: widget.album,
      from: from,
      tilt: tiltFor(widget.album.id, small: widget.size == PrintSize.small),
      print: ({required fanned}) {
        Widget print() =>
            _print(size: PrintSize.large, fanned: fanned, tilted: false);
        final covers = _covers;
        // Riffle images may still be decrypting when the peek opens
        return covers == null
            ? print()
            : ListenableBuilder(
                listenable: covers, builder: (_, __) => print());
      },
    );
    setState(() => _lifted = true);
    void land() {
      if (mounted && _lifted) setState(() => _lifted = false);
    }

    // Stay hidden until the print has flown back or tucked away
    unawaited(route.completed.then((_) => land()));
    final pushed = Navigator.of(context, rootNavigator: true).push(route);
    route.animation?.addStatusListener((status) {
      if (status == AnimationStatus.dismissed) land();
    });
    final action = await pushed;
    if (!mounted) return;
    switch (action) {
      case ShelfPeekAction.open:
        widget.onTap();
      case ShelfPeekAction.people:
        final people =
            context.findAncestorWidgetOfExactType<ShelfScreen>()?.onOpenPeople;
        await people?.call(widget.album);
      case ShelfPeekAction.rename:
        final messenger = ScaffoldMessenger.of(context);
        if (await renameAlbum(context, albumId: widget.album.id) == false) {
          messenger.showSnackBar(
              const SnackBar(content: Text(AlbumCopy.renameFailed)));
        }
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final covers = _covers;
    if (covers != null) context.watch<ShelfCovers>();
    context.watch<CoverCache?>();
    context.watch<AppState>();

    final card = Opacity(
      opacity: _lifted ? 0 : 1,
      child: _print(
        size: widget.size,
        onHold: () =>
            covers?.ensureRiffle(widget.album.id, widget.album.previewMedia),
        onTap: widget.onTap,
        onPeek: _peek,
      ),
    );
    if (Fx.noEntry) return card;
    return AnimatedSlide(
      offset: _entered ? Offset.zero : const Offset(0, 0.07),
      duration: Warm.springSoft,
      curve: Warm.easeSoft,
      child: AnimatedOpacity(
        opacity: _entered ? 1 : 0,
        duration: Warm.springSoft,
        curve: Warm.easeSoft,
        child: card,
      ),
    );
  }
}

class _Blank extends StatelessWidget {
  final VoidCallback? onTap;

  const _Blank({this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Warm.pagePad, 32, Warm.pagePad, 0),
      child: GestureDetector(
        onTap: onTap,
        child: Transform.rotate(
          angle: -1.4 * 3.141592653589793 / 180,
          child: PrintCard(
            frame: true,
            blank: true,
            chin: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Your first album', style: Warm.cardTitle),
                  const SizedBox(height: 5),
                  Text('Tap to make it', style: Warm.meta),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
