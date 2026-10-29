import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:miuchio/data/storage/activity_store.dart';
import 'package:miuchio/domain/activity/activity_event.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/tab_dock.dart';
import 'package:miuchio/ui/widgets/warm_button.dart';

import 'activity_card.dart';
import 'activity_copy.dart';
import 'activity_row.dart';

const Duration _swap = Duration(milliseconds: 180);

class ActivityScreen extends StatefulWidget {
  final ActivityFeed store;
  final ActivityNames names;
  final Future<void> Function()? refresh;
  final ActivityThumb? thumb;
  // An album's latest photo, for the albums you were added to
  final Widget? Function(String albumId)? cover;
  final void Function(String albumId)? onOpenAlbum;
  // Only persisted verification resolves the alerted key
  final Future<void> Function(SafetyNumberChanged event)? onCompare;
  final void Function(bool unread)? onUnreadChanged;
  // A home tab rather than a page: no back, and room for the dock
  final bool asTab;

  const ActivityScreen({
    super.key,
    required this.store,
    required this.names,
    this.refresh,
    this.thumb,
    this.cover,
    this.onOpenAlbum,
    this.onCompare,
    this.onUnreadChanged,
    this.asTab = false,
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

  @override
  void initState() {
    super.initState();
    _load();
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
    // Open where the news is, unless Security has anything new of its own
    bool fresh(ActivityLane lane) => _rows.any((r) =>
        r.event.lane == lane &&
        (!r.seen || (r.event.needsDecision && !r.dismissed)));
    if (mounted &&
        !fresh(ActivityLane.security) &&
        fresh(ActivityLane.albums)) {
      setState(() => _lane = ActivityLane.albums);
    }
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
    // Once opened or dismissed an arrival is done, not history
    final arrived = albums
        .where((r) =>
            r.event is InvitedToAlbum &&
            !r.dismissed &&
            !_quieted.contains(r.event.id))
        .toList();
    final history = albums.where((r) => r.event is! InvitedToAlbum).toList();

    return Scaffold(
      backgroundColor: Warm.ground,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: EdgeInsets.fromLTRB(Warm.pagePad, 21, Warm.pagePad,
              widget.asTab ? TabDock.height + 48 : 48),
          children: [
            if (widget.asTab)
              const SizedBox(height: 22)
            else ...[
              const Align(alignment: Alignment.centerLeft, child: _Back()),
              const SizedBox(height: 27),
            ],
            Text('Notifications', style: Warm.pageTitle),
            const SizedBox(height: 14),
            _Segmented(
              lane: _lane,
              onSelect: _select,
              // The number is what waits on you; a dot is only something new
              securityCount: needs.length,
              albumsCount: arrived.length,
              securityMeta:
                  needs.isEmpty ? 'Up to date' : '${needs.length} to review',
              albumsMeta:
                  arrived.isEmpty ? 'Nothing new' : '${arrived.length} new',
              securityAttention: security.any((r) => !r.seen),
              albumsAttention: albums.any((r) => !r.seen),
            ),
            if (!_loading)
              AnimatedSwitcher(
                duration: _swap,
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                layoutBuilder: (current, previous) => Stack(
                  alignment: Alignment.topCenter,
                  children: [...previous, if (current != null) current],
                ),
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.015),
                      end: Offset.zero,
                    ).animate(a),
                    child: child,
                  ),
                ),
                child: _lane == ActivityLane.security
                    ? _SecurityPanel(
                        key: const ValueKey(ActivityLane.security),
                        needs: needs,
                        rest: rest,
                        names: widget.names,
                        onQuiet: _handleQuiet,
                        onGo: _handleGo,
                        onOpenAlbum: widget.onOpenAlbum,
                      )
                    : _AlbumsPanel(
                        key: const ValueKey(ActivityLane.albums),
                        arrived: arrived,
                        rows: history,
                        names: widget.names,
                        thumb: widget.thumb,
                        cover: widget.cover,
                        onOpenAlbum: widget.onOpenAlbum,
                        onOpen: _handleGo,
                        onDismiss: _handleQuiet,
                      ),
              ),
          ],
        ),
      ),
    );
  }

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

class _Back extends StatelessWidget {
  const _Back();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      key: ValueKey('activity-back'),
      width: 48,
      height: 48,
      child: Align(alignment: Alignment.centerLeft, child: WarmBack()),
    );
  }
}

class _Segmented extends StatelessWidget {
  final ActivityLane lane;
  final void Function(ActivityLane lane) onSelect;
  final int securityCount;
  final int albumsCount;
  final String securityMeta;
  final String albumsMeta;
  final bool securityAttention;
  final bool albumsAttention;

  const _Segmented({
    required this.lane,
    required this.onSelect,
    required this.securityCount,
    required this.albumsCount,
    required this.securityMeta,
    required this.albumsMeta,
    required this.securityAttention,
    required this.albumsAttention,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _Tab(
          label: 'Security',
          meta: securityMeta,
          count: securityCount,
          urgent: true,
          active: lane == ActivityLane.security,
          attention: securityAttention,
          attentionKey: const ValueKey('attention-security'),
          onTap: () => onSelect(ActivityLane.security),
        ),
        const SizedBox(width: 26),
        _Tab(
          label: 'Albums',
          meta: albumsMeta,
          count: albumsCount,
          active: lane == ActivityLane.albums,
          attention: albumsAttention,
          attentionKey: const ValueKey('attention-albums'),
          onTap: () => onSelect(ActivityLane.albums),
        ),
      ],
    );
  }
}

class _Tab extends StatelessWidget {
  final String label;
  final String meta;
  final int count;
  // Waiting security items are alarms; waiting albums are just news
  final bool urgent;
  final bool active;
  final bool attention;
  final Key attentionKey;
  final VoidCallback onTap;

  const _Tab({
    required this.label,
    required this.meta,
    this.count = 0,
    this.urgent = false,
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
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Padding(
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
                    if (count > 0) ...[
                      const SizedBox(width: 7),
                      Container(
                        key: attentionKey,
                        constraints: const BoxConstraints(minWidth: 20),
                        height: 20,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          color: urgent ? Warm.warn : Warm.cta,
                        ),
                        child: Text(
                          '$count',
                          style: Warm.acTabMeta.copyWith(
                              color: Warm.paper,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ] else if (attention) ...[
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
              Positioned(
                left: 0,
                bottom: 0,
                child: AnimatedContainer(
                  duration: _swap,
                  curve: Curves.easeOutCubic,
                  width: active ? 18 : 0,
                  height: 2.5,
                  decoration: BoxDecoration(
                    color: Warm.ink,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SecurityPanel extends StatelessWidget {
  final List<StoredActivity> needs;
  final List<StoredActivity> rest;
  final ActivityNames names;
  final void Function(ActivityEvent e) onQuiet;
  final void Function(ActivityEvent e) onGo;
  final void Function(String albumId)? onOpenAlbum;

  const _SecurityPanel({
    super.key,
    required this.needs,
    required this.rest,
    required this.names,
    required this.onQuiet,
    required this.onGo,
    this.onOpenAlbum,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (needs.isEmpty && rest.isEmpty)
          const _Blank('Nothing has changed about who can see your albums.'),
        if (needs.isNotEmpty) const SizedBox(height: 30),
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
                    ? _face(needs[i].event, names,
                        alarm: needs[i].event is SafetyNumberChanged)
                    : null,
                onGo: () => onGo(needs[i].event),
                onQuiet: () => onQuiet(needs[i].event),
              ),
            ),
          ),
        ..._grouped(rest, names, onOpenAlbum, null),
      ],
    );
  }
}

class _AlbumsPanel extends StatelessWidget {
  final List<StoredActivity> arrived;
  final List<StoredActivity> rows;
  final ActivityNames names;
  final ActivityThumb? thumb;
  final Widget? Function(String albumId)? cover;
  final void Function(String albumId)? onOpenAlbum;
  final void Function(ActivityEvent e) onOpen;
  final void Function(ActivityEvent e) onDismiss;

  const _AlbumsPanel({
    super.key,
    required this.arrived,
    required this.rows,
    required this.names,
    this.thumb,
    this.cover,
    this.onOpenAlbum,
    required this.onOpen,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (arrived.isEmpty && rows.isEmpty)
          const _Blank('Nothing has been added to your albums yet.'),
        if (arrived.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 30),
            child: SharedAlbumsCard(
              albums: [
                for (final r in arrived)
                  (
                    albumId: r.event.albumId,
                    title: names.albumTitle(r.event.albumId),
                  ),
              ],
              when: addedWhen(arrived.first.event.at),
              cover: cover,
              onOpen: (id) => onOpen(
                  arrived.firstWhere((r) => r.event.albumId == id).event),
              onDismiss: () {
                for (final r in arrived) {
                  onDismiss(r.event);
                }
              },
            ),
          ),
        ..._grouped(rows, names, onOpenAlbum, thumb),
      ],
    );
  }
}

List<Widget> _grouped(
  List<StoredActivity> rows,
  ActivityNames names,
  void Function(String albumId)? onOpenAlbum,
  ActivityThumb? thumb,
) {
  final out = <Widget>[];
  String? lastDay;
  var i = 0;
  for (final r in rows) {
    final day = dayLabel(r.event.at);
    if (day != lastDay) {
      out.add(Padding(
        padding: const EdgeInsets.only(top: 30, bottom: 13),
        child: Text(day.toUpperCase(), style: Warm.acDay),
      ));
      lastDay = day;
    }
    final e = r.event;
    final previews = e is PhotosAdded ? e.previews : const <MediaRecord>[];
    out.add(_Enter(
      key: ValueKey(e.id),
      index: i++,
      child: ActivityRow(
        line: lineFor(e, names),
        face: _face(e, names),
        previews: previews,
        more: e is PhotosAdded ? math.max(0, e.count - previews.length) : 0,
        thumb: thumb,
        onTap: onOpenAlbum == null ? null : () => onOpenAlbum(e.albumId),
      ),
    ));
  }
  return out;
}

String? _personToken(ActivityEvent e) => switch (e) {
      SafetyNumberChanged() => e.peerToken,
      MemberJoined() => e.memberToken,
      MemberLeft() => e.memberToken,
      PhotosAdded() => e.uploaderToken,
      _ => null,
    };

ActivityFace _face(ActivityEvent e, ActivityNames names, {bool alarm = false}) {
  final token = _personToken(e);
  return ActivityFace(
    albumId: e.albumId,
    name: token == null ? null : names.memberName(e.albumId, token),
    token: token,
    alarm: alarm,
  );
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
      padding: const EdgeInsets.only(top: 60),
      child: Text(line, style: Warm.acBlank),
    );
  }
}
