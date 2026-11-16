import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miuchio/data/api/user_api.dart';
import 'package:miuchio/data/models/album_model.dart';
import 'package:miuchio/data/storage/media_cache_manager.dart';
import 'package:miuchio/data/storage/media_catalog.dart';
import 'package:miuchio/data/storage/safety_store.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/ui/album/leave_photos_choice.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/shelf/still_print.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/encrypted_thumbnail.dart';
import 'package:miuchio/ui/widgets/upload_copy.dart';
import 'package:miuchio/ui/widgets/warm_button.dart';
import 'package:provider/provider.dart';

// One page a settings row opens: bare back, optional glyph, title, then content
class SettingsPage extends StatelessWidget {
  final String title;
  final IconData? glyph;
  final List<Widget> children;
  // Long content built lazily below the children
  final List<Widget> slivers;

  const SettingsPage({
    super.key,
    required this.title,
    required this.children,
    this.glyph,
    this.slivers = const [],
  });

  static const _physics =
      BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());

  @override
  Widget build(BuildContext context) {
    final head = [
      const Align(alignment: Alignment.centerLeft, child: WarmBack()),
      Padding(
        padding: const EdgeInsets.only(left: 8, top: 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (glyph != null) ...[
              Icon(glyph, size: 30, color: Warm.inkSoft),
              const SizedBox(height: 18),
            ],
            Text(title, style: Warm.pageTitle),
            ...children,
          ],
        ),
      ),
    ];
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Warm.overlayOnGround,
      child: Scaffold(
        backgroundColor: Warm.ground,
        body: SafeArea(
          bottom: false,
          child: slivers.isEmpty
              ? ListView(
                  physics: _physics,
                  padding: const EdgeInsets.fromLTRB(
                      Warm.pagePad - 8, 16, Warm.pagePad, 56),
                  children: head,
                )
              : CustomScrollView(
                  physics: _physics,
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(
                          Warm.pagePad - 8, 16, Warm.pagePad, 0),
                      sliver: SliverList.list(children: head),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(
                          Warm.pagePad, 0, Warm.pagePad, 56),
                      sliver: SliverMainAxisGroup(slivers: slivers),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class SettingsLead extends StatelessWidget {
  final String text;

  const SettingsLead(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(text, style: Warm.pageLead),
      );
}

class SettingsSoft extends StatelessWidget {
  final String text;

  const SettingsSoft(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 26),
        child: Text(text, style: Warm.pageSoft),
      );
}

class SettingsFacts extends StatelessWidget {
  final List<(IconData, String)> facts;

  const SettingsFacts(this.facts, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Column(
        children: [
          for (final (icon, text) in facts)
            Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(icon, size: 18, color: Warm.inkSoft),
                  ),
                  const SizedBox(width: 14),
                  Expanded(child: Text(text, style: Warm.pageFact)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class SettingsPills<T> extends StatelessWidget {
  final List<(String, T, int?)> options;
  final T value;
  final ValueChanged<T> onChanged;

  const SettingsPills({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    Widget pill(String label, T option, int? count) {
      final selected = option == value;
      final style =
          Warm.meta.copyWith(color: selected ? Warm.ctaInk : Warm.inkSoft);
      return Semantics(
        button: true,
        selected: selected,
        child: GestureDetector(
          onTap: () {
            if (selected) return;
            HapticFeedback.selectionClick();
            onChanged(option);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: selected ? Warm.ink : const Color(0x00000000),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: selected ? Warm.ink : Warm.inkGhost, width: 1),
            ),
            child: Text.rich(TextSpan(text: label, style: style, children: [
              if (count != null && count > 0)
                TextSpan(
                  text: '  $count',
                  style: style.copyWith(
                    fontWeight: FontWeight.w600,
                    fontVariations: const [FontVariation('wght', 650)],
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
            ])),
          ),
        ),
      );
    }

    return Row(
      children: [
        for (var i = 0; i < options.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          pill(options[i].$1, options[i].$2, options[i].$3),
        ],
      ],
    );
  }
}

class SoonTag extends StatelessWidget {
  final String label;

  const SoonTag(this.label, {super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: Warm.inkGhost,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Text(label,
            style: Warm.sectionLabel.copyWith(
                fontSize: 11, letterSpacing: 0.2, color: Warm.inkSoft)),
      );
}

class BackupPage extends StatefulWidget {
  const BackupPage({super.key});

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  bool _lost = false;

  @override
  Widget build(BuildContext context) => SettingsPage(
        title: 'Backup',
        glyph: Icons.cloud_outlined,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Text('Not available yet', style: Warm.pageLead),
                const SoonTag('Coming soon'),
              ],
            ),
          ),
          _KeyMap(lost: _lost),
          const SizedBox(height: 28),
          SettingsPills<bool>(
            options: const [
              ('This phone', false, null),
              ('Phone lost', true, null)
            ],
            value: _lost,
            onChanged: (v) => setState(() => _lost = v),
          ),
          const SizedBox(height: 16),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topLeft,
              children: [...previous, if (current != null) current],
            ),
            child: Text(
              _lost
                  ? "There's no backup yet. If you lose this phone, your "
                      "albums can't be brought back. Make a new account and "
                      'ask people to add you again. Backup is coming in a '
                      'later beta.'
                  : 'Your albums open with the keys on this phone. Not even '
                      'Miuchio has a copy.',
              key: ValueKey(_lost),
              style: Warm.pageFact.copyWith(fontSize: 14, color: Warm.inkSoft),
            ),
          ),
        ],
      );
}

// Where the keys are: the phone holds them, Miuchio only holds locked photos
class _KeyMap extends StatelessWidget {
  final bool lost;

  const _KeyMap({required this.lost});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 300),
              curve: Warm.easeOut,
              opacity: lost ? 0.35 : 1,
              child: _KeyNode(
                icon: Icons.smartphone_outlined,
                title: 'This phone',
                note: lost ? 'Gone, with the keys' : 'Holds the keys',
                badge: AnimatedScale(
                  duration: const Duration(milliseconds: 350),
                  curve: Warm.easeOut,
                  scale: lost ? 0 : 1,
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: Warm.cocoa,
                      shape: BoxShape.circle,
                      border: Border.all(color: Warm.ground, width: 2),
                    ),
                    child: const Icon(Icons.vpn_key_outlined,
                        size: 12, color: Warm.ctaInk),
                  ),
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 28),
            child: SizedBox(
              width: 38,
              height: 1.5,
              child: CustomPaint(painter: _DashPainter()),
            ),
          ),
          const Expanded(
            child: _KeyNode(
              icon: Icons.cloud_outlined,
              title: 'Miuchio',
              note: 'Locked photos, no keys',
            ),
          ),
        ],
      ),
    );
  }
}

class _KeyNode extends StatelessWidget {
  final IconData icon;
  final String title;
  final String note;
  final Widget? badge;

  const _KeyNode({
    required this.icon,
    required this.title,
    required this.note,
    this.badge,
  });

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  gradient: Warm.stoneFill,
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: Warm.stoneShadow,
                ),
                child: Icon(icon, size: 26, color: Warm.ink),
              ),
              if (badge != null)
                Positioned(right: -5, bottom: -5, child: badge!),
            ],
          ),
          const SizedBox(height: 11),
          Text(title, style: Warm.pageSubhead.copyWith(fontSize: 14)),
          const SizedBox(height: 3),
          AnimatedSwitcher(
            duration: Warm.quick,
            child: Text(note,
                key: ValueKey(note),
                textAlign: TextAlign.center,
                style: Warm.pageSoft.copyWith(fontSize: 12, height: 1.3)),
          ),
        ],
      );
}

class _DashPainter extends CustomPainter {
  const _DashPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Warm.inkGhost
      ..strokeWidth = size.height;
    final y = size.height / 2;
    for (var x = 0.0; x < size.width; x += 6) {
      canvas.drawLine(Offset(x, y), Offset(x + 3, y), paint);
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => false;
}

class LeavingPage extends StatefulWidget {
  const LeavingPage({super.key});

  @override
  State<LeavingPage> createState() => _LeavingPageState();
}

class _LeavingPageState extends State<LeavingPage> {
  bool _saving = false;
  List<MediaRecord> _yours = const [];
  List<MediaRecord> _others = const [];

  @override
  void initState() {
    super.initState();
    _loadPhotos();
  }

  // The newest thumbnails this phone already shows, only from albums opened
  Future<void> _loadPhotos() async {
    final MediaCatalog catalog;
    try {
      catalog = context.read<MediaCatalog>();
    } catch (_) {
      return;
    }
    final safety = context.read<SafetyStore?>();
    // Most recently active albums first, stopping once every slot is filled
    final albums = [...context.read<AppState>().albums]..sort((a, b) =>
        (b.latestActivityAt ?? b.createdAt)
            .compareTo(a.latestActivityAt ?? a.createdAt));
    const wantYours = 2, wantOthers = 4, page = 30;
    final yours = <MediaRecord>[];
    final others = <MediaRecord>[];
    bool full() => yours.length >= wantYours && others.length >= wantOthers;
    for (final a in albums) {
      if (full()) break;
      if (safety?.accepted(a.id) == false) continue;
      // A page at a time in the album's own order, newest first
      for (var offset = 0; !full(); offset += page) {
        final rows = await catalog.listRecordsForAlbum(a.id,
            limit: page, offset: offset);
        for (final r in rows) {
          if (!r.hasThumb) continue;
          if (r.uploaderToken == a.memberToken) {
            if (yours.length < wantYours) yours.add(r);
          } else if (others.length < wantOthers) {
            others.add(r);
          }
          if (full()) break;
        }
        // Corrupt rows are skipped, so only an empty page ends the album
        if (rows.isEmpty) break;
      }
    }
    if (!mounted) return;
    setState(() {
      _yours = yours;
      _others = others;
    });
  }

  List<Widget> _thumbs(List<MediaRecord> records) {
    final MediaCacheManager cache;
    try {
      cache = context.read<MediaCacheManager>();
    } catch (_) {
      return const [];
    }
    return [
      for (final r in records) EncryptedThumbnail(record: r, cache: cache)
    ];
  }

  Future<void> _set(bool delete) async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final was = state.deleteMediaOnLeave;
    setState(() => _saving = true);
    state.setDeleteMediaOnLeave(delete);
    final saved = await UserService().setDeleteMediaOnLeave(delete);
    if (!saved) {
      state.setDeleteMediaOnLeave(was);
      messenger.showSnackBar(const SnackBar(
        content: Text("Couldn't save that. Try again."),
        behavior: SnackBarBehavior.floating,
      ));
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final delete = context.select<AppState, bool>((s) => s.deleteMediaOnLeave);
    return SettingsPage(
      title: 'When you leave',
      glyph: Icons.logout_rounded,
      children: [
        const SettingsLead('What happens to the photos you added when you '
            'leave an album or are removed.'),
        LeavePhotosPreview(
          delete: delete,
          yours: _thumbs(_yours),
          others: _thumbs(_others),
        ),
        const SizedBox(height: 14),
        LeavePhotosChoice(
            delete: delete, onChanged: _saving ? null : _set, short: true),
        const SettingsSoft('You can still choose each time you leave. Deleting '
            "your account deletes your photos in albums you're still in."),
      ],
    );
  }
}

class StoragePage extends StatefulWidget {
  const StoragePage({super.key});

  @override
  State<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends State<StoragePage> {
  ({int thumbs, int full})? _usage;
  ({int used, int quota})? _account;
  bool _accountLoaded = false;
  bool _clearing = false;
  List<_AlbumShare> _split = const [];
  String? _picked;

  MediaCacheManager? get _cache {
    try {
      return context.read<MediaCacheManager>();
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
    _loadAccount();
    _loadSplit();
  }

  // Only your own uploads count toward your space, and every one of them was
  // sent from this phone, so the local catalog splits it exactly
  Future<void> _loadSplit() async {
    final MediaCatalog catalog;
    try {
      catalog = context.read<MediaCatalog>();
    } catch (_) {
      return;
    }
    final albums = context.read<AppState>().albums;
    final split = <_AlbumShare>[];
    for (final a in albums) {
      final me = a.memberToken;
      if (me == null) continue;
      final mine = (await catalog.listRecordsForAlbum(a.id))
          .where((r) => r.uploaderToken == me);
      final bytes =
          mine.fold<int>(0, (n, r) => n + r.blobSize + (r.thumbSize ?? 0));
      if (bytes > 0) split.add(_AlbumShare(a, mine.length, bytes));
    }
    split.sort((a, b) => b.bytes.compareTo(a.bytes));
    if (mounted) setState(() => _split = split);
  }

  void _pick(String id) => setState(() => _picked = _picked == id ? null : id);

  Future<void> _loadAccount() async {
    final account = await UserService().getStorage();
    if (!mounted) return;
    setState(() {
      _account = account;
      _accountLoaded = true;
    });
  }

  Future<void> _load() async {
    final usage = await _cache?.usage();
    if (mounted) setState(() => _usage = usage);
  }

  Future<void> _clear() async {
    final cache = _cache;
    if (cache == null || _clearing) return;
    setState(() => _clearing = true);
    try {
      await cache.clearFullPhotos();
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
    await _load();
  }

  // Whatever the albums on this phone don't explain, such as photos kept in
  // albums you left, profile photos and covers
  List<_Share> _shares(({int used, int quota}) account) {
    // Nothing known yet, so the bar shows the whole total as one
    if (_split.isEmpty) {
      return [
        _Share(id: 'all', title: '', note: '', bytes: account.used),
      ];
    }
    final state = context.read<AppState>();
    final known = _split.fold<int>(0, (n, a) => n + a.bytes);
    final rest = account.used - known;
    final all = [
      for (final a in _split)
        _Share(
          id: a.album.id,
          title: state.albumDisplayName(a.album.id) ?? 'Album',
          note: '${a.photos} ${a.photos == 1 ? 'photo' : 'photos'}',
          bytes: a.bytes,
          album: a.album,
        ),
      if (rest > 0)
        _Share(
            id: 'other',
            title: 'Other',
            // Broken by hand so every phone wraps it the same way
            note: 'Photos kept after leaving,\nprofile photos, covers',
            bytes: rest),
    ];
    // One ink, lighter for each smaller share, so the bar needs no colours
    return [
      for (var i = 0; i < all.length; i++)
        all[i].shaded(math.max(0.22, 1 - i * 0.2)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final u = _usage;
    final full = u?.full ?? 0;
    final account = _account;
    // Hidden once loaded without a limit, or when the server can't be reached
    final showAccount =
        !_accountLoaded || (account != null && account.quota > 0);
    return SettingsPage(
      title: 'Storage',
      children: [
        if (showAccount) ...[
          Padding(
            padding: const EdgeInsets.only(top: 22),
            child: Text(account == null ? '…' : formatBytes(account.used),
                style: Warm.storageTotal),
          ),
          Text(
              account == null
                  ? ''
                  : 'of ${formatBytes(account.quota)}, your space during the '
                      'beta',
              style: Warm.pageLead),
          const SizedBox(height: 14),
          _SplitBar(
            shares: account == null || account.quota == 0
                ? const []
                : _shares(account),
            quota: account?.quota ?? 0,
            picked: _picked,
            onPick: _pick,
          ),
          if (account != null && _split.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Column(children: [
                for (final share in _shares(account))
                  _ShareRow(
                    share: share,
                    dim: _picked != null && _picked != share.id,
                    onTap: () => _pick(share.id),
                  ),
              ]),
            ),
        ],
        const SizedBox(height: 34),
        Row(
          children: [
            Expanded(child: Text('Cache on this phone', style: Warm.rowTitle)),
            Text(u == null ? '…' : formatBytes(u.thumbs + u.full),
                style: Warm.rowValue),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('Previews stay so albums open offline.',
              style: Warm.pageSoft),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: Transform.translate(
            offset: const Offset(-12, 0),
            child: WarmTextButton(
              label: 'Clear full photos',
              color: Warm.ink,
              onTap: full == 0 || _clearing ? null : _clear,
            ),
          ),
        ),
      ],
    );
  }
}

class _AlbumShare {
  final AlbumModel album;
  final int photos;
  final int bytes;

  const _AlbumShare(this.album, this.photos, this.bytes);
}

class _Share {
  final String id;
  final String title;
  final String note;
  final int bytes;
  final AlbumModel? album;
  final double shade;

  const _Share({
    required this.id,
    required this.title,
    required this.note,
    required this.bytes,
    this.album,
    this.shade = 1,
  });

  _Share shaded(double shade) => _Share(
      id: id,
      title: title,
      note: note,
      bytes: bytes,
      album: album,
      shade: shade);
}

class _SplitBar extends StatelessWidget {
  final List<_Share> shares;
  final int quota;
  final String? picked;
  final ValueChanged<String> onPick;

  const _SplitBar({
    required this.shares,
    required this.quota,
    required this.picked,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 8,
        child: ColoredBox(
          color: const Color(0x0F1C1917),
          child: LayoutBuilder(builder: (context, box) {
            // Gaps come out first and the filled part never passes the end,
            // even at full capacity
            // With many albums the gaps shrink so they never take more than a
            // quarter of the bar
            final gaps = shares.length - 1;
            final gap =
                gaps <= 0 ? 0.0 : math.min(1.5, box.maxWidth / 4 / gaps);
            final room = math.max(0.0, box.maxWidth - gap * gaps);
            final used = shares.fold<int>(0, (n, s) => n + s.bytes);
            final fill = quota == 0 ? 0.0 : room * math.min(1.0, used / quota);
            return Row(
              children: [
                for (var i = 0; i < shares.length; i++) ...[
                  if (i > 0) SizedBox(width: gap),
                  GestureDetector(
                    onTap: () => onPick(shares[i].id),
                    child: AnimatedOpacity(
                      duration: Warm.quick,
                      opacity: picked == null || picked == shares[i].id
                          ? shares[i].shade
                          : shares[i].shade * 0.3,
                      child: SizedBox(
                        width: used == 0 ? 0 : fill * shares[i].bytes / used,
                        child: const ColoredBox(color: Warm.cocoa),
                      ),
                    ),
                  ),
                ],
              ],
            );
          }),
        ),
      ),
    );
  }
}

class _ShareRow extends StatelessWidget {
  final _Share share;
  final bool dim;
  final VoidCallback onTap;

  const _ShareRow(
      {required this.share, required this.dim, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final album = share.album;
    final cover = album == null ? null : printPhoto(context, album, 0);
    final px = (34 * MediaQuery.devicePixelRatioOf(context)).round();
    return Semantics(
      button: true,
      label: '${share.title}, ${share.note}, ${formatBytes(share.bytes)}',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedOpacity(
          duration: Warm.quick,
          opacity: dim ? 0.4 : 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Opacity(
                  opacity: share.shade,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: Warm.cocoa,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(width: 11),
                Container(
                  width: 34,
                  height: 34,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: Warm.wellEmpty,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: cover == null
                      ? null
                      : Image.memory(cover,
                          fit: BoxFit.cover,
                          cacheWidth: px,
                          gaplessPlayback: true),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(share.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Warm.rowTitle
                              .copyWith(fontSize: 14, letterSpacing: -0.1)),
                      const SizedBox(height: 1),
                      Text(share.note,
                          style: Warm.pageSoft
                              .copyWith(fontSize: 12, height: 1.3)),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(formatBytes(share.bytes),
                    style: Warm.rowValue.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()])),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
