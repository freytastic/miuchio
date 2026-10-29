import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:miuchio/data/api/media_api.dart';
import 'package:miuchio/data/models/album_model.dart';
import 'package:miuchio/data/storage/media_cache_manager.dart';
import 'package:miuchio/data/storage/media_catalog.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/ui/album/photo_sheets.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/screens/photo_viewer_screen.dart';
import 'package:miuchio/ui/shelf/shelf_copy.dart';
import 'package:miuchio/ui/shelf/shelf_data.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/encrypted_thumbnail.dart';
import 'package:miuchio/ui/widgets/member_face.dart';
import 'package:miuchio/ui/widgets/tab_dock.dart';

import 'feed_posts.dart';

// What the people you share with added since you last looked, newest first.
// Built on this phone alone: the shelf listing says which albums moved past
// their seen marker, and each photo's place in its album says which are new
class HomeScreen extends StatefulWidget {
  final void Function(String albumId)? onOpenAlbum;
  final Future<void> Function()? onRefresh;
  // Test seams; the app reads these from its providers
  final Future<List<MediaRecord>> Function(String albumId)? listMedia;
  final Widget Function(MediaRecord record)? thumb;

  const HomeScreen({
    super.key,
    this.onOpenAlbum,
    this.onRefresh,
    this.listMedia,
    this.thumb,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Everything shown this visit stays until the tab is left, so a post does
  // not vanish the moment it is marked seen
  final Map<String, MediaRecord> _shown = {};
  // The generation each album was listed at, which marking seen moves to
  final Map<String, int> _listedAt = {};
  final Map<String, GlobalKey> _keys = {};
  final Set<String> _viewed = {};
  // How far each album's marker was moved this visit; photos arriving after
  // it move it again
  final Map<String, int> _marked = {};
  String? _signature;
  bool _loaded = false;
  int _loads = 0;

  T? _maybe<T>() {
    try {
      return context.read<T>();
    } catch (_) {
      return null;
    }
  }

  Future<List<MediaRecord>> _list(String albumId) =>
      widget.listMedia?.call(albumId) ??
      context.read<MediaApi>().listMedia(albumId);

  Future<void> _load(List<AlbumModel> albums) async {
    final load = ++_loads;
    final seen = _maybe<SeenStore>();
    final catalog = _maybe<MediaCatalog>();
    final fresh = <MediaRecord>[];

    Future<void> one(AlbumModel a) async {
      final lastSeen = seen?.lastSeen(a.id) ?? 0;
      final unseen = unseenCount(
        generation: a.mediaGeneration,
        lastSeen: lastSeen,
        mediaCount: a.mediaCount,
        own: seen?.ownThrough(a.id, a.mediaGeneration) ?? 0,
      );
      if (unseen == 0) return;
      List<MediaRecord> records;
      try {
        records = await _list(a.id);
      } catch (_) {
        // Offline still shows what this phone already holds
        records = await catalog?.listRecordsForAlbum(a.id) ?? const [];
      }
      _listedAt[a.id] = a.mediaGeneration;
      fresh.addAll(unseenIn(records,
          lastSeen: lastSeen, unseen: unseen, me: a.memberToken));
    }

    await Future.wait([
      for (final a in albums)
        if (a.hasSummary) one(a)
    ]);
    if (!mounted || load != _loads) return;
    setState(() {
      for (final r in fresh) {
        _shown[r.id] = r;
      }
      _loaded = true;
    });
    _scheduleCheck();
  }

  bool _checkPending = false;

  // Scroll events can land mid layout, so positions are read after the frame
  bool _scheduleCheck() {
    if (_checkPending) return false;
    _checkPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPending = false;
      _checkViewed();
    });
    return false;
  }

  // A section counts as seen once its last photo clears the dock
  void _checkViewed() {
    if (!mounted) return;
    final media = MediaQuery.of(context);
    final floor = media.size.height - media.padding.bottom - TabDock.height;
    for (final e in _keys.entries) {
      if (_viewed.contains(e.key)) continue;
      final box = e.value.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
      if (bottom <= floor) _viewed.add(e.key);
    }
    _markAlbums();
  }

  // An album's marker moves once its whole section has been scrolled past
  void _markAlbums() {
    final seen = _maybe<SeenStore>();
    if (seen == null) return;
    for (final u in groupByAlbum(_shown.values)) {
      final gen = _listedAt[u.albumId];
      if (gen == null || (_marked[u.albumId] ?? -1) >= gen) continue;
      if (!_viewed.contains(_keyOf(u))) continue;
      _marked[u.albumId] = gen;
      unawaited(seen.markSeen(u.albumId, gen).catchError((_) {}));
    }
  }

  // Newer photos joining a section make it a section to see again
  static String _keyOf(AlbumUpdate u) => '${u.albumId}/${u.photos.first.id}';

  void _openPhoto(AlbumUpdate update, int index) {
    final state = context.read<AppState>();
    String? nameOf(String token) =>
        state.memberDisplayName(update.albumId, token);
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PhotoViewerScreen(
        records: update.photos,
        initialIndex: index,
        cache: context.read<MediaCacheManager>(),
        nameOf: nameOf,
        faceOf: (token, size) =>
            _face(update.albumId, token, nameOf(token), size),
        // Others' photos only, so there is nothing here to delete
        isOwner: (_) => false,
        onDelete: (_) async => false,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final albums = [
      for (final a in state.albums)
        if (!state.isDeleting(a.id)) a
    ];
    final signature =
        [for (final a in albums) '${a.id}:${a.mediaGeneration}'].join(',');
    if (signature != _signature) {
      _signature = signature;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_load(albums));
      });
    }

    final present = {for (final a in albums) a.id};
    final updates =
        groupByAlbum(_shown.values.where((r) => present.contains(r.albumId)));
    _keys.removeWhere((k, _) => !updates.any((u) => _keyOf(u) == k));

    return Scaffold(
      backgroundColor: Warm.ground,
      body: SafeArea(
        bottom: false,
        child: NotificationListener<ScrollNotification>(
          onNotification: (_) => _scheduleCheck(),
          child: RefreshIndicator(
            color: Warm.ink,
            onRefresh: widget.onRefresh ?? () async {},
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding:
                  const EdgeInsets.only(top: 43, bottom: TabDock.height + 48),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Warm.pagePad),
                  child: Text('Home', style: Warm.pageTitle),
                ),
                for (final u in updates)
                  Padding(
                    key: _keys.putIfAbsent(_keyOf(u), GlobalKey.new),
                    padding: const EdgeInsets.only(top: 34),
                    child: _AlbumSection(
                      update: u,
                      album: state.albumDisplayName(u.albumId) ?? 'An album',
                      byline: _byline(u, state),
                      faces: [
                        for (final t in u.uploaders.take(3))
                          _face(u.albumId, t,
                              state.memberDisplayName(u.albumId, t), 36),
                      ],
                      thumb: (r) =>
                          widget.thumb?.call(r) ??
                          EncryptedThumbnail(
                            record: r,
                            cache: context.read<MediaCacheManager>(),
                          ),
                      onOpenPhoto: (i) => _openPhoto(u, i),
                      onOpenAlbum: widget.onOpenAlbum == null
                          ? null
                          : () => widget.onOpenAlbum!(u.albumId),
                    ),
                  ),
                if (_loaded)
                  Padding(
                    padding: EdgeInsets.fromLTRB(Warm.pagePad,
                        updates.isEmpty ? 30 : 40, Warm.pagePad, 0),
                    child: Text("You're all caught up.", style: Warm.acBlank),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // "Alice added 3 photos · Today", naming at most two people
  static String _byline(AlbumUpdate u, AppState state) {
    final names = [
      for (final t in u.uploaders)
        state.memberDisplayName(u.albumId, t) ?? 'Someone'
    ];
    final who = switch (names.length) {
      1 => names[0],
      2 => '${names[0]} and ${names[1]}',
      _ => '${names[0]}, ${names[1]} and ${names.length - 2} more',
    };
    final n = u.photos.length;
    return '$who added $n photo${n == 1 ? '' : 's'} · '
        '${formatPhotoDay(u.at)}';
  }
}

Widget _face(String albumId, String token, String? name, double size) =>
    MemberFace(
      albumId: albumId,
      token: token,
      name: name,
      size: size,
      style: Warm.acFace.copyWith(fontSize: size * 0.36),
      border: Border.all(color: Warm.ground, width: 2),
    );

// The album's name and who added what, then every new photo in full width,
// one under the next
class _AlbumSection extends StatelessWidget {
  final AlbumUpdate update;
  final String album;
  final String byline;
  final List<Widget> faces;
  final Widget Function(MediaRecord record) thumb;
  final void Function(int index) onOpenPhoto;
  final VoidCallback? onOpenAlbum;

  const _AlbumSection({
    required this.update,
    required this.album,
    required this.byline,
    required this.faces,
    required this.thumb,
    required this.onOpenPhoto,
    this.onOpenAlbum,
  });

  @override
  Widget build(BuildContext context) {
    final photos = update.photos;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onOpenAlbum,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Warm.pagePad),
            child: Row(
              children: [
                SizedBox(
                  width: 36.0 + 22 * (faces.length - 1),
                  height: 36,
                  child: Stack(
                    children: [
                      for (var i = faces.length - 1; i >= 0; i--)
                        Positioned(left: 22.0 * i, child: faces[i]),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(album,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Warm.rowTitle),
                      const SizedBox(height: 2),
                      Text(byline,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Warm.rowValue),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < photos.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 4),
            child: GestureDetector(
              onTap: () => onOpenPhoto(i),
              child: AspectRatio(
                aspectRatio: 4 / 5,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const ColoredBox(color: Warm.wellEmpty),
                    thumb(photos[i]),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
