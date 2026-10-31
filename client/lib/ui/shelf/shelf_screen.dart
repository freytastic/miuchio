import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:miuchio/diagnostics/fx.dart';
import 'package:miuchio/diagnostics/perf_probe.dart';
import 'package:miuchio/data/models/album_model.dart';
import 'package:miuchio/data/storage/cover_cache.dart';
import 'package:miuchio/data/storage/own_avatar_store.dart';
import 'package:miuchio/domain/avatar/avatar_publisher.dart';
import 'package:miuchio/ui/album/album_copy.dart';
import 'package:miuchio/ui/album/album_rename.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/shelf/album_print.dart';
import 'package:miuchio/ui/shelf/develop_store.dart';
import 'package:miuchio/ui/shelf/print_style.dart';
import 'package:miuchio/ui/shelf/shelf_bench.dart';
import 'package:miuchio/ui/shelf/shelf_copy.dart';
import 'package:miuchio/ui/shelf/shelf_data.dart';
import 'package:miuchio/ui/shelf/shelf_layout.dart';
import 'package:miuchio/ui/shelf/shelf_peek.dart';
import 'package:miuchio/ui/shelf/shelf_view_preference.dart';
import 'package:miuchio/ui/shelf/still_print.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/foot_bar.dart';
import 'package:miuchio/ui/widgets/member_face.dart';
import 'package:miuchio/ui/widgets/print_card.dart';
import 'package:miuchio/ui/widgets/upload_pill.dart';

part 'shelf_grid.dart';
part 'shelf_header.dart';

class ShelfScreen extends StatefulWidget {
  final VoidCallback? onOpenProfile;
  final Future<void> Function(AlbumModel album)? onOpenAlbum;
  final VoidCallback? onCreateAlbum;
  // The + button, which may offer more than a new album
  final VoidCallback? onMake;
  final VoidCallback? onOpenActivity;
  final Future<void> Function(AlbumModel album)? onOpenPeople;

  const ShelfScreen({
    super.key,
    this.onOpenProfile,
    this.onOpenAlbum,
    this.onCreateAlbum,
    this.onMake,
    this.onOpenActivity,
    this.onOpenPeople,
  });

  @override
  State<ShelfScreen> createState() => _ShelfScreenState();
}

class _ShelfScreenState extends State<ShelfScreen>
    with TickerProviderStateMixin {
  // Used only when no saved preference is provided, as in widget tests
  ShelfView _localView = ShelfView.stacked;

  ShelfViewPreference? get _viewPref {
    try {
      return context.read<ShelfViewPreference>();
    } catch (_) {
      return null;
    }
  }

  void _setView(ShelfView v) {
    final pref = _viewPref;
    if (pref != null) {
      unawaited(pref.set(v));
    } else {
      setState(() => _localView = v);
    }
  }

  late final DevelopStore _develop = DevelopStore(
      vsync: this, duration: Warm.develop, visible: () => _current);

  bool _current = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Turns true as a page over the shelf starts closing
    _current = ModalRoute.isCurrentOf(context) ?? true;
    if (_current) _develop.play();
  }

  // Prevents entry animation replay after layout remounts
  final Set<String> _entered = {};

  final ScrollController? _benchScroll = Fx.bench ? ScrollController() : null;
  int _benchRound = 0;

  @override
  void initState() {
    super.initState();
    final scroll = _benchScroll;
    if (scroll == null) return;
    unawaited(ShelfBench(
      scroll: scroll,
      replayEntry: () => setState(() {
        _entered.clear();
        _benchRound++;
      }),
      replayDevelop: _develop.replay,
      idle: () => mounted && (ModalRoute.of(context)?.isCurrent ?? true),
    ).run());
  }

  @override
  void dispose() {
    _benchScroll?.dispose();
    _develop.dispose();
    super.dispose();
  }

  void _watch<T>(BuildContext context) {
    try {
      context.watch<T>();
    } catch (_) {}
  }

  SeenStore? get _seen {
    try {
      return context.read<SeenStore>();
    } catch (_) {
      return null;
    }
  }

  int _unseenFor(AlbumModel a) {
    final store = _seen;
    // Missing summary means unknown rather than zero
    if (store == null || !a.hasSummary) return 0;
    return unseenCount(
      generation: a.mediaGeneration,
      lastSeen: store.lastSeen(a.id),
      mediaCount: a.mediaCount,
      own: store.ownThrough(a.id, a.mediaGeneration),
    );
  }

  Future<void> _open(AlbumModel album) async {
    await _seen?.markSeen(album.id, album.mediaGeneration);
    if (!mounted) return;
    await widget.onOpenAlbum?.call(album);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _watch<SeenStore>(context);
    _watch<ShelfViewPreference>(context);
    final view = _viewPref?.view ?? _localView;
    final albums = state.albums.where((a) => !state.isDeleting(a.id)).toList();

    final entries = <ShelfEntry>[];
    for (final a in albums) {
      final unseen = _unseenFor(a);
      _develop.sync(a.id, unseen);
      entries.add(ShelfEntry(
        id: a.id,
        title: state.albumDisplayName(a.id),
        unseen: unseen,
        lastActivity: a.latestActivityAt,
      ));
    }
    _develop.retain({for (final a in albums) a.id});
    final headline = headlineFor(entries);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Warm.overlayOnGround,
      child: Scaffold(
        backgroundColor: Warm.ground,
        body: Stack(
          children: [
            const _Ground(),
            _Scroll(
              key: Fx.bench ? ValueKey(_benchRound) : null,
              controller: _benchScroll,
              view: view,
              albums: albums,
              headline: headline,
              unseenFor: _unseenFor,
              develop: _develop,
              entered: _entered,
              onSetView: _setView,
              onOpenProfile: widget.onOpenProfile,
              onOpenAlbum: _open,
              onCreateAlbum: widget.onCreateAlbum,
            ),
            const _BarScrim(),
            _Bar(
              unread: state.hasUnreadNotifications,
              onCreate: widget.onMake ?? widget.onCreateAlbum,
              onActivity: widget.onOpenActivity,
            ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 132,
              child: Center(child: UploadPill()),
            ),
          ],
        ),
      ),
    );
  }
}

class _Ground extends StatelessWidget {
  const _Ground();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
        decoration: BoxDecoration(
          color: Warm.ground,
          gradient: RadialGradient(
            center: Alignment(0, -1.4),
            radius: 1.4,
            colors: [Warm.groundLift, Warm.ground],
          ),
        ),
        child: SizedBox.expand(),
      );
}

class _Scroll extends StatelessWidget {
  final ScrollController? controller;
  final ShelfView view;
  final List<AlbumModel> albums;
  final Headline headline;
  final int Function(AlbumModel) unseenFor;
  final DevelopStore develop;
  final Set<String> entered;
  final ValueChanged<ShelfView> onSetView;
  final VoidCallback? onOpenProfile;
  final void Function(AlbumModel) onOpenAlbum;
  final VoidCallback? onCreateAlbum;

  const _Scroll({
    super.key,
    this.controller,
    required this.view,
    required this.albums,
    required this.headline,
    required this.unseenFor,
    required this.develop,
    required this.entered,
    required this.onSetView,
    required this.onOpenProfile,
    required this.onOpenAlbum,
    required this.onCreateAlbum,
  });

  // Header row: 21 above the 48px tap targets
  static const double _headerHeight = 69;
  // The bottom bar is 96 above the inset, plus air so names aren't in the fade
  static const double _barClearance = 104;

  // Compact only, and only when a pair of small prints sits under the lead
  double _leadScale(BuildContext context, List<ShelfSlot<AlbumModel>> plan) {
    if (view != ShelfView.compact ||
        plan.length < 2 ||
        plan[1].size != PrintSize.small) {
      return 1;
    }
    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final width = size.width - Warm.pagePad * 2;
    final scaler = MediaQuery.textScalerOf(context);
    double textHeight(String text, TextStyle style) => (TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
        )..layout(maxWidth: width))
            .height;
    final say = _Say.top +
        textHeight(headline.title, Warm.h1) +
        (headline.sub.isEmpty
            ? 0
            : _Say.gap + textHeight(headline.sub, Warm.sub));
    final small = (width - _Grid.pairGap) / 2 * _Grid.printAspect;
    return leadScale(
      viewHeight: size.height - pad.bottom - _barClearance,
      above: pad.top + _headerHeight + say + _Grid.topFor(view),
      leadHeight: width * _Grid.printAspect,
      below: _Grid.rowGapFor(view) + small,
    );
  }

  @override
  Widget build(BuildContext context) {
    final plan = planFor(albums, view);
    final lead = _leadScale(context, plan);

    return SafeArea(
      bottom: false,
      // Slivers prevent offscreen cards from requesting covers
      child: CustomScrollView(
        controller: controller,
        physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics()),
        slivers: [
          SliverToBoxAdapter(
            child: _Header(
              view: view,
              onSetView: onSetView,
              onOpenProfile: onOpenProfile,
            ),
          ),
          SliverToBoxAdapter(child: _Say(headline: headline)),
          if (albums.isEmpty)
            SliverToBoxAdapter(child: _Blank(onTap: onCreateAlbum))
          else ...[
            _Grid(
              plan: plan,
              view: view,
              leadScale: lead,
              unseenFor: unseenFor,
              develop: develop,
              entered: entered,
              onOpenAlbum: onOpenAlbum,
            ),
            const SliverToBoxAdapter(child: _FootMark()),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 148)),
        ],
      ),
    );
  }
}

class _FootMark extends StatelessWidget {
  const _FootMark();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 38),
      child: Text('Your photos are end-to-end encrypted',
          textAlign: TextAlign.center, style: Warm.footMark),
    );
  }
}

class _BarScrim extends StatelessWidget {
  const _BarScrim();

  @override
  Widget build(BuildContext context) => const Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: FootScrim(height: 190),
      );
}

class _Bar extends StatelessWidget {
  final bool unread;
  final VoidCallback? onCreate;
  final VoidCallback? onActivity;

  const _Bar(
      {required this.unread, required this.onCreate, required this.onActivity});

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: 96 + bottom,
      child: Padding(
        padding: EdgeInsets.only(left: 44, right: 44, bottom: 18 + bottom),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Albums', style: Warm.tab.copyWith(color: Warm.ink)),
            MakeButton(onTap: onCreate),
            GestureDetector(
              onTap: onActivity,
              behavior: HitTestBehavior.opaque,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Text('Activity', style: Warm.tab),
                  if (unread)
                    const Positioned(
                      top: 4,
                      right: -7,
                      child: SizedBox(
                        width: 5,
                        height: 5,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Warm.warn,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
