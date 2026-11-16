import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miuchio/e2ee/identity_trust.dart';
import 'package:miuchio/ui/album/member_avatars.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/foot_bar.dart';
import 'package:miuchio/ui/widgets/page_bar.dart';
import 'package:miuchio/ui/widgets/warm_button.dart';

class PersonEntry {
  final String id;
  final String name;
  final Widget face;
  final TrustState trust;
  // Invited but not joined: no key yet, so nothing to compare
  final bool invited;
  final bool owner;
  final String? detail;

  const PersonEntry({
    required this.id,
    required this.name,
    required this.face,
    this.trust = TrustState.unverified,
    this.invited = false,
    this.owner = false,
    this.detail,
  });
}

// Verifying is optional, so an unverified person looks normal. Only a changed
// number is allowed to be loud
class PeopleScreen extends StatefulWidget {
  final String title;
  final String subtitle;
  final Future<List<PersonEntry>> Function() load;
  final Future<void> Function(PersonEntry entry) onOpen;
  final Future<void> Function()? onAdd;
  // Null leaves invited rows inert
  final Future<void> Function(PersonEntry entry)? onOpenInvited;
  final String? note;

  const PeopleScreen({
    super.key,
    required this.title,
    required this.subtitle,
    required this.load,
    required this.onOpen,
    this.onAdd,
    this.onOpenInvited,
    this.note,
  });

  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<PeopleScreen> {
  List<PersonEntry>? _people;
  bool _failed = false;
  // Just verified: their row lands in Verified and its check pops in
  Set<String> _fresh = const {};
  final ScrollController _scroll = ScrollController();

  static const _sections = [
    (TrustState.changed, 'Changed'),
    (TrustState.unverified, 'Not verified'),
    (TrustState.verified, 'Verified'),
  ];

  static const _rank = {
    TrustState.changed: 0,
    TrustState.unverified: 1,
    TrustState.verified: 2,
  };

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final people = await widget.load();
      people.sort((a, b) {
        if (a.invited != b.invited) return a.invited ? 1 : -1;
        return _rank[a.trust]!.compareTo(_rank[b.trust]!);
      });
      final was = {
        for (final p in _people ?? const <PersonEntry>[]) p.id: p.trust
      };
      if (mounted) {
        setState(() {
          _fresh = {
            for (final p in people)
              if (p.trust == TrustState.verified &&
                  was[p.id] != null &&
                  was[p.id] != TrustState.verified)
                p.id,
          };
          _people = people;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _open(PersonEntry p) async {
    HapticFeedback.selectionClick();
    final open = p.invited ? widget.onOpenInvited : widget.onOpen;
    await open?.call(p);
    await _reload();
  }

  Future<void> _add() async {
    await widget.onAdd?.call();
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final people = _people;
    final joined = people?.where((p) => !p.invited).toList() ?? const [];
    final done = joined.where((p) => p.trust == TrustState.verified).length;
    final invited = people?.where((p) => p.invited).toList() ?? const [];
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Warm.overlayOnGround,
      child: Scaffold(
        backgroundColor: Warm.ground,
        body: SafeArea(
          bottom: false,
          child: CustomScrollView(
            controller: _scroll,
            physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics()),
            slivers: [
              PageBar(
                scroll: _scroll,
                after: 70,
                title: Text(widget.title),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                    Warm.pagePad - 8, 18, Warm.pagePad - 8, 0),
                sliver: SliverList.list(children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                                child:
                                    Text(widget.title, style: Warm.pageTitle)),
                            const SizedBox(width: 16),
                            if (people != null)
                              _VerifiedRing(done: done, total: joined.length),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          people == null
                              ? widget.subtitle
                              : '${widget.subtitle} · $done of '
                                  '${joined.length} verified',
                          style: Warm.rowValue,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (widget.onAdd != null)
                    _Row(
                      face: MakeButton(size: 40, onTap: _add),
                      name: 'Add someone',
                      onTap: _add,
                    ),
                  if (_failed)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text("Couldn't load people.",
                                style: Warm.pageSoft),
                          ),
                          WarmTextButton(label: 'Try again', onTap: _reload),
                        ],
                      ),
                    )
                  else if (people == null)
                    const Padding(
                      padding: EdgeInsets.only(top: 20),
                      child: Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Warm.ink),
                        ),
                      ),
                    ),
                ]),
              ),
              if (!_failed && people != null)
                for (final (trust, label) in _sections)
                  if (joined.any((p) => p.trust == trust))
                    _section(trust, label,
                        joined.where((p) => p.trust == trust).toList()),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                    Warm.pagePad - 8, 0, Warm.pagePad - 8, 56),
                sliver: SliverList.list(children: [
                  if (!_failed)
                    for (final p in invited) _person(p),
                  if (widget.note != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 14, 8, 0),
                      child: Text(widget.note!, style: Warm.pageSoft),
                    ),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(TrustState trust, String label, List<PersonEntry> rows) {
    final alarm = trust == TrustState.changed;
    final style = Warm.sectionLabel.copyWith(
      fontWeight: FontWeight.w600,
      fontVariations: const [FontVariation('wght', 620)],
      color: alarm ? Warm.warn : Warm.inkFaint,
    );
    return SliverMainAxisGroup(slivers: [
      const SliverToBoxAdapter(child: SizedBox(height: 14)),
      PinnedLabel(
        padding: const EdgeInsets.fromLTRB(Warm.pagePad, 12, Warm.pagePad, 8),
        child: Row(
          children: [
            Expanded(child: Text(label.toUpperCase(), style: style)),
            Text('${rows.length}',
                style: style.copyWith(
                    letterSpacing: 0,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ],
        ),
      ),
      SliverPadding(
        padding:
            const EdgeInsets.fromLTRB(Warm.pagePad - 8, 2, Warm.pagePad - 8, 0),
        sliver: SliverList.list(children: [for (final p in rows) _person(p)]),
      ),
    ]);
  }

  Widget _person(PersonEntry p) {
    final row = _Row(
      key: ValueKey('person-${p.id}'),
      face: p.invited ? const DashedCircle(size: 40) : p.face,
      name: p.name,
      owner: p.owner,
      verified: p.trust == TrustState.verified,
      fresh: _fresh.contains(p.id),
      status:
          p.trust == TrustState.changed ? 'Security code changed' : p.detail,
      alarm: p.trust == TrustState.changed,
      onTap: p.invited && widget.onOpenInvited == null ? null : () => _open(p),
    );
    return _fresh.contains(p.id) ? _Arrive(child: row) : row;
  }
}

class _Row extends StatelessWidget {
  final Widget face;
  final String name;
  final String? status;
  final bool owner;
  final bool verified;
  final bool fresh;
  final bool alarm;
  final VoidCallback? onTap;

  const _Row({
    super.key,
    required this.face,
    required this.name,
    this.status,
    this.owner = false,
    this.verified = false,
    this.fresh = false,
    this.alarm = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      label: [
        name,
        if (owner) 'owner',
        if (verified) 'verified',
        if (status != null) status!,
      ].join(', '),
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            children: [
              SizedBox(width: 40, height: 40, child: face),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(name,
                              style: Warm.rowTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ),
                        if (verified) ...[
                          const SizedBox(width: 5),
                          fresh
                              ? const _CheckPop()
                              : const Icon(Icons.check_rounded,
                                  size: 15, color: Warm.ink),
                        ],
                        if (owner) ...[
                          const SizedBox(width: 8),
                          const _OwnerTag(),
                        ],
                      ],
                    ),
                    if (status != null) ...[
                      const SizedBox(height: 1),
                      Text(
                        status!,
                        style: alarm
                            ? Warm.rowValue.copyWith(color: Warm.warn)
                            : Warm.rowValue.copyWith(color: Warm.inkFaint),
                      ),
                    ],
                  ],
                ),
              ),
              if (onTap != null)
                const Icon(Icons.chevron_right_rounded,
                    size: 17, color: Warm.inkGhost),
            ],
          ),
        ),
      ),
    );
  }
}

class _OwnerTag extends StatelessWidget {
  const _OwnerTag();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: Warm.inkGhost,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text('OWNER',
            style: Warm.sectionLabel.copyWith(letterSpacing: 0.3)),
      );
}

// A row that just moved into Verified fades in and glows once
class _Arrive extends StatelessWidget {
  final Widget child;

  const _Arrive({required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 2100),
      builder: (context, t, child) {
        final shown = Curves.easeOut.transform((t / 0.22).clamp(0.0, 1.0));
        // Holds the glow, then lets it fade out
        final glow =
            t < 0.4 ? 1.0 : 1 - Curves.easeOut.transform((t - 0.4) / 0.6);
        return Opacity(
          opacity: shown,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Warm.cocoa.withValues(alpha: 0.07 * glow),
              borderRadius: BorderRadius.circular(14),
            ),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

class _CheckPop extends StatelessWidget {
  const _CheckPop();

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 900),
      curve: const Interval(0.42, 1, curve: Curves.elasticOut),
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.scale(scale: t, child: child),
      ),
      child: const Icon(Icons.check_rounded, size: 15, color: Warm.ink),
    );
  }
}

class _VerifiedRing extends StatelessWidget {
  final int done;
  final int total;

  const _VerifiedRing({required this.done, required this.total});

  @override
  Widget build(BuildContext context) {
    final share = total == 0 ? 0.0 : done / total;
    return Semantics(
      label: '$done of $total verified',
      excludeSemantics: true,
      child: SizedBox(
        width: 44,
        height: 44,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: share),
          duration: const Duration(milliseconds: 1100),
          curve: const Interval(0.18, 1, curve: Warm.easeOut),
          builder: (context, v, child) => CustomPaint(
            painter: _RingPainter(v),
            child: child,
          ),
          child: Center(
            child: Text('$done',
                style: Warm.rowValue.copyWith(
                    fontWeight: FontWeight.w600,
                    fontVariations: const [FontVariation('wght', 650)],
                    color: Warm.ink,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double share;

  const _RingPainter(this.share);

  static const double _radius = 19;
  static const double _stroke = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final rect =
        Rect.fromCircle(center: size.center(Offset.zero), radius: _radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke;
    canvas.drawCircle(rect.center, _radius, paint..color = Warm.inkGhost);
    if (share <= 0) return;
    canvas.drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi * share,
        false,
        paint
          ..color = Warm.cocoa
          ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.share != share;
}
