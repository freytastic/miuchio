import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:miuchio/data/storage/activity_store.dart';
import 'package:miuchio/domain/activity/activity_event.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/page_bar.dart';

import 'activity_card.dart';
import 'activity_copy.dart';
import 'activity_row.dart';

const Duration _swap = Duration(milliseconds: 180);

class ActivityScreen extends StatefulWidget {
  final ActivityFeed store;
  final ActivityNames names;
  final Future<void> Function()? refresh;
  final ActivityThumb? thumb;
  final ActivityAlbumPhoto? albumPhoto;
  final void Function(String albumId)? onOpenAlbum;
  // Only persisted verification resolves the alerted key
  final Future<void> Function(SafetyNumberChanged event)? onCompare;
  final void Function(bool unread)? onUnreadChanged;

  const ActivityScreen({
    super.key,
    required this.store,
    required this.names,
    this.refresh,
    this.thumb,
    this.albumPhoto,
    this.onOpenAlbum,
    this.onCompare,
    this.onUnreadChanged,
  });

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  ActivityLane _lane = ActivityLane.security;
  List<StoredActivity> _rows = const [];
  bool _loading = true;
  // Hide answered cards while dismissal is still being saved
  final Set<String> _quieted = {};
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _select(ActivityLane lane) {
    if (lane == _lane) return;
    setState(() => _lane = lane);
    unawaited(_readCurrentLane());
  }

  // Mark only the visible lane so the other tab keeps its unread state
  Future<void> _readCurrentLane() async {
    final lane = _lane;
    final unread = _rows
        .where((r) => r.event.lane == lane && !r.seen)
        .map((r) => r.event.id)
        .toList();
    if (unread.isEmpty) return;
    await widget.store.markSeen(unread);
    if (!mounted) return;
    setState(() {
      _rows = [
        for (final r in _rows)
          unread.contains(r.event.id)
              ? StoredActivity(
                  event: r.event, seen: true, dismissed: r.dismissed)
              : r,
      ];
    });
    _announceUnread();
  }

  void _announceUnread() =>
      widget.onUnreadChanged?.call(_rows.any((r) => !r.seen));

  Future<void> _load() async {
    try {
      await widget.refresh?.call();
    } catch (_) {
      // Show stored activity even if refresh fails
    }
    await _reread();
    _announceUnread();
    await _readCurrentLane();
  }

  Future<void> _reread() async {
    final rows = await widget.store.read();
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  List<StoredActivity> _of(ActivityLane lane) =>
      _rows.where((r) => r.event.lane == lane).toList();

  @override
  Widget build(BuildContext context) {
    final security = _of(ActivityLane.security);
    final albums = _of(ActivityLane.albums);
    final needs = security
        .where((r) =>
            r.event.needsDecision &&
            !r.dismissed &&
            !_quieted.contains(r.event.id))
        .toList();
    final rest = security.where((r) => !needs.contains(r)).toList();
    final added = [
      for (final r in albums)
        if (r.event case final PhotosAdded p) p,
    ];
    final photos = added.fold<int>(0, (n, p) => n + p.count);

    final alarm =
        needs.map((r) => r.event).whereType<SafetyNumberChanged>().firstOrNull;
    final say = _lane == ActivityLane.security
        ? sayForSecurity(
            needs: needs.length,
            happened: rest.length,
            changedSafetyNumber: alarm == null
                ? null
                : widget.names.memberName(alarm.albumId, alarm.peerToken),
          )
        : sayForAlbums(
            photos: photos,
            albums: added.map((p) => p.albumId).toSet().length,
          );

    return Scaffold(
      backgroundColor: Warm.ground,
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          controller: _scroll,
          slivers: [
            PageBar(
              scroll: _scroll,
              after: 120,
              pad: Warm.pagePad,
              backKey: const ValueKey('activity-back'),
              title: const Text('Activity'),
            ),
            SliverPadding(
              padding:
                  const EdgeInsets.fromLTRB(Warm.pagePad, 36, Warm.pagePad, 0),
              sliver: SliverList.list(children: [
                _Heading(say: say),
                const SizedBox(height: 20),
                _Segmented(
                  lane: _lane,
                  onSelect: _select,
                  securityMeta: needs.isEmpty
                      ? 'Up to date'
                      : '${needs.length} to review',
                  albumsMeta: '$photos photo${photos == 1 ? '' : 's'}',
                  securityAttention:
                      needs.isNotEmpty || security.any((r) => !r.seen),
                  albumsAttention: albums.any((r) => !r.seen),
                ),
              ]),
            ),
            if (!_loading)
              _LaneFade(
                lane: _lane,
                sliver: SliverMainAxisGroup(
                  key: ValueKey(_lane),
                  slivers: _lane == ActivityLane.security
                      ? _securitySlivers(needs, rest)
                      : _albumsSlivers(albums),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 48)),
          ],
        ),
      ),
    );
  }

  List<Widget> _securitySlivers(
      List<StoredActivity> needs, List<StoredActivity> rest) {
    final names = widget.names;
    return [
      if (needs.isEmpty && rest.isEmpty)
        const SliverToBoxAdapter(
            child:
                _Blank('Nothing has changed about who can see your albums.')),
      if (needs.isNotEmpty)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(Warm.pagePad, 30, Warm.pagePad, 0),
          sliver: SliverList.list(children: [
            for (var i = 0; i < needs.length; i++)
              _Enter(
                key: ValueKey(needs[i].event.id),
                index: i,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: ActivityCard(
                    copy: cardCopyFor(needs[i].event, names),
                    alarm: needs[i].event is SafetyNumberChanged,
                    face: _personToken(needs[i].event) != null
                        ? _face(needs[i].event, names, widget.albumPhoto,
                            alarm: needs[i].event is SafetyNumberChanged)
                        : null,
                    onGo: () => _handleGo(needs[i].event),
                    onQuiet: () => _handleQuiet(needs[i].event),
                  ),
                ),
              ),
          ]),
        ),
      ..._grouped(rest, names, widget.onOpenAlbum, null, widget.albumPhoto),
    ];
  }

  List<Widget> _albumsSlivers(List<StoredActivity> rows) => [
        if (rows.isEmpty)
          const SliverToBoxAdapter(
              child: _Blank('Nothing has been added to your albums yet.')),
        ..._grouped(rows, widget.names, widget.onOpenAlbum, widget.thumb,
            widget.albumPhoto),
      ];

  void _handleQuiet(ActivityEvent e) => _answer(e);

  void _answer(ActivityEvent e) {
    setState(() => _quieted.add(e.id));
    unawaited(widget.store.dismiss(e.id).catchError((_) {}));
  }

  Future<void> _handleGo(ActivityEvent e) async {
    // Backing out of Compare must leave the alarm standing
    if (e is SafetyNumberChanged) {
      await widget.onCompare?.call(e);
      await _reread();
      return;
    }
    _answer(e);
    switch (e) {
      case InvitedToAlbum():
        widget.onOpenAlbum?.call(e.albumId);
      case RemovedFromAlbum():
        break; // "Okay" only acknowledges because the album is already gone
      default:
        break;
    }
  }
}

class _Heading extends StatelessWidget {
  final Say say;
  const _Heading({required this.say});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 160),
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topLeft,
        children: [...previous, if (current != null) current],
      ),
      transitionBuilder: (child, a) => FadeTransition(
        opacity: a,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.12),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
          child: child,
        ),
      ),
      child: Column(
        key: ValueKey(say.title + say.sub),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(say.title, style: Warm.h1),
          const SizedBox(height: 8),
          Text(say.sub, style: Warm.sub),
        ],
      ),
    );
  }
}

class _Segmented extends StatefulWidget {
  final ActivityLane lane;
  final void Function(ActivityLane lane) onSelect;
  final String securityMeta;
  final String albumsMeta;
  final bool securityAttention;
  final bool albumsAttention;

  const _Segmented({
    required this.lane,
    required this.onSelect,
    required this.securityMeta,
    required this.albumsMeta,
    required this.securityAttention,
    required this.albumsAttention,
  });

  @override
  State<_Segmented> createState() => _SegmentedState();
}

class _SegmentedState extends State<_Segmented> {
  final _albumsKey = GlobalKey();
  // Where the Albums tab starts, read after layout so the line can slide to it
  double _albumsLeft = 0;

  void _measure() {
    final tab = _albumsKey.currentContext?.findRenderObject() as RenderBox?;
    final row = context.findRenderObject() as RenderBox?;
    if (tab == null || row == null || !tab.hasSize) return;
    final left = tab.localToGlobal(Offset.zero, ancestor: row).dx;
    if (left != _albumsLeft) setState(() => _albumsLeft = left);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _measure();
    });
    final albums = widget.lane == ActivityLane.albums;
    return Stack(
      children: [
        Row(
          children: [
            _Tab(
              label: 'Security',
              meta: widget.securityMeta,
              active: !albums,
              attention: widget.securityAttention,
              attentionKey: const ValueKey('attention-security'),
              onTap: () => widget.onSelect(ActivityLane.security),
            ),
            const SizedBox(width: 26),
            _Tab(
              key: _albumsKey,
              label: 'Albums',
              meta: widget.albumsMeta,
              active: albums,
              attention: widget.albumsAttention,
              attentionKey: const ValueKey('attention-albums'),
              onTap: () => widget.onSelect(ActivityLane.albums),
            ),
          ],
        ),
        AnimatedPositioned(
          duration: Warm.springSnappy,
          curve: Warm.easeOut,
          left: albums ? _albumsLeft : 0,
          bottom: 0,
          child: IgnorePointer(
            child: Container(
              width: 18,
              height: 2.5,
              decoration: BoxDecoration(
                color: Warm.ink,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Tab extends StatelessWidget {
  final String label;
  final String meta;
  final bool active;
  final bool attention;
  final Key attentionKey;
  final VoidCallback onTap;

  const _Tab({
    super.key,
    required this.label,
    required this.meta,
    required this.active,
    required this.attention,
    required this.attentionKey,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: active,
      label: '$label, $meta',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedDefaultTextStyle(
                  duration: _swap,
                  style: Warm.acTab
                      .copyWith(color: active ? Warm.ink : Warm.inkFaint),
                  child: Text(label, maxLines: 1),
                ),
                if (attention) ...[
                  const SizedBox(width: 6),
                  Container(
                    key: attentionKey,
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Warm.warn,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// One section per day, its label sticking under the bar while its rows pass
List<Widget> _grouped(
  List<StoredActivity> rows,
  ActivityNames names,
  void Function(String albumId)? onOpenAlbum,
  ActivityThumb? thumb,
  ActivityAlbumPhoto? albumPhoto,
) {
  final days = <(String, List<StoredActivity>)>[];
  for (final r in rows) {
    final day = dayLabel(r.event.at);
    if (days.isNotEmpty && days.last.$1 == day) {
      days.last.$2.add(r);
    } else {
      days.add((day, [r]));
    }
  }
  var i = 0;
  return [
    for (final (day, rows) in days)
      SliverMainAxisGroup(slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 18)),
        PinnedLabel(
          padding: const EdgeInsets.fromLTRB(Warm.pagePad, 12, Warm.pagePad, 9),
          child: Text(day.toUpperCase(), style: Warm.acDay),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(Warm.pagePad, 4, Warm.pagePad, 0),
          sliver: SliverList.list(children: [
            for (final r in rows)
              _row(r.event, i++, names, onOpenAlbum, thumb, albumPhoto),
          ]),
        ),
      ]),
  ];
}

Widget _row(
  ActivityEvent e,
  int index,
  ActivityNames names,
  void Function(String albumId)? onOpenAlbum,
  ActivityThumb? thumb,
  ActivityAlbumPhoto? albumPhoto,
) {
  final previews = e is PhotosAdded ? e.previews : const <MediaRecord>[];
  return _Enter(
    key: ValueKey(e.id),
    index: index,
    child: ActivityRow(
      line: lineFor(e, names),
      face: _face(e, names, albumPhoto, badge: true),
      previews: previews,
      more: e is PhotosAdded ? math.max(0, e.count - previews.length) : 0,
      thumb: thumb,
      onTap: onOpenAlbum == null ? null : () => onOpenAlbum(e.albumId),
    ),
  );
}

String? _personToken(ActivityEvent e) => switch (e) {
      SafetyNumberChanged() => e.peerToken,
      MemberJoined() => e.memberToken,
      CoverChanged() => e.setBy,
      MemberLeft() => e.memberToken,
      PhotosAdded() => e.uploaderToken,
      _ => null,
    };

// What happened, as a small mark on the face, since the person is the face
IconData? _mark(ActivityEvent e) => switch (e) {
      MemberJoined() => Icons.person_add_alt_rounded,
      MemberLeft() => Icons.logout_rounded,
      CoverChanged() => Icons.photo_outlined,
      PhotosAdded() => Icons.add_photo_alternate_outlined,
      SafetyNumberChanged() => Icons.fingerprint_rounded,
      _ => null,
    };

// Events about you have no face, so their glyph stands in for one
IconData? _glyph(ActivityEvent e) => switch (e) {
      OwnerChanged() => Icons.verified_user_outlined,
      InvitedToAlbum() => Icons.photo_album_outlined,
      RemovedFromAlbum() => Icons.block_rounded,
      _ => null,
    };

ActivityFace _face(
    ActivityEvent e, ActivityNames names, ActivityAlbumPhoto? albumPhoto,
    {bool alarm = false, bool badge = false}) {
  final token = _personToken(e);
  return ActivityFace(
    // Ownership is about the album, so the album's newest photo shows it
    albumPhoto: e is OwnerChanged ? albumPhoto?.call(e.albumId) : null,
    albumId: e.albumId,
    name: token == null ? null : names.memberName(e.albumId, token),
    token: token,
    alarm: alarm,
    glyph: token == null ? _glyph(e) : null,
    mark: badge && token != null ? _mark(e) : null,
    markWarn: e is SafetyNumberChanged && !e.verified,
  );
}

class _LaneFade extends StatefulWidget {
  final ActivityLane lane;
  final Widget sliver;

  const _LaneFade({required this.lane, required this.sliver});

  @override
  State<_LaneFade> createState() => _LaneFadeState();
}

class _LaneFadeState extends State<_LaneFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _in =
      AnimationController(vsync: this, duration: _swap, value: 1);
  late final Animation<double> _opacity =
      CurvedAnimation(parent: _in, curve: Curves.easeOutCubic);

  @override
  void didUpdateWidget(_LaneFade old) {
    super.didUpdateWidget(old);
    if (old.lane != widget.lane) _in.forward(from: 0);
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SliverFadeTransition(opacity: _opacity, sliver: widget.sliver);
}

class _Enter extends StatelessWidget {
  final int index;
  final Widget child;
  const _Enter({super.key, required this.index, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 300 + (index.clamp(0, 6) * 55)),
      curve: Curves.easeOutCubic,
      builder: (_, t, c) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 14 * (1 - t)), child: c),
      ),
      child: child,
    );
  }
}

class _Blank extends StatelessWidget {
  final String line;
  const _Blank(this.line);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Warm.pagePad, 60, Warm.pagePad, 0),
      child: Text(line, style: Warm.acBlank),
    );
  }
}
