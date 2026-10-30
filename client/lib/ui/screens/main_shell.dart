import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:miuchio/data/api/album_api.dart';
import 'package:miuchio/data/models/album_model.dart';
import 'package:miuchio/data/models/album_summary.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/people/everyone.dart';
import 'package:miuchio/ui/screens/album_detail_screen.dart';
import 'package:miuchio/ui/create/create_album_screen.dart';
import 'package:miuchio/ui/home/home_screen.dart';
import 'package:miuchio/ui/navigation/screen_route.dart';
import 'package:miuchio/ui/screens/notifications_screen.dart';
import 'package:miuchio/ui/shelf/album_print.dart';
import 'package:miuchio/ui/shelf/profile_screen.dart';
import 'package:miuchio/ui/shelf/shelf_screen.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/album_cover.dart';
import 'package:miuchio/ui/widgets/tab_dock.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  HomeTab _tab = HomeTab.home;

  void _select(HomeTab tab) => setState(() => _tab = tab);

  Future<void> _create() async {
    HapticFeedback.mediumImpact();
    final appState = context.read<AppState>();
    await Navigator.of(context).push(screenRoute(const CreateAlbumScreen()));
    await _refresh(appState);
  }

  Future<void> _openAlbum(AlbumModel album, {bool add = false}) async {
    final appState = context.read<AppState>();
    await Navigator.of(context)
        .push(screenRoute(AlbumDetailScreen(album: album, addOnOpen: add)));
    // Refresh without delaying shelf development
    unawaited(_refresh(appState));
  }

  Future<void> _openAlbumById(String albumId) async {
    final album = context
        .read<AppState>()
        .albums
        .where((a) => a.id == albumId)
        .firstOrNull;
    if (album != null) await _openAlbum(album);
  }

  // Keep stale albums when refresh fails
  static Future<void> _refresh(AppState appState) async {
    final fresh = await AlbumService().getMyAlbums();
    if (fresh != null) appState.applyListing(fresh);
  }

  // Adding photos is the common case, so it comes first. With no albums yet
  // there is nowhere to add them, so the button starts one
  Future<void> _make() async {
    final albums = [
      for (final a in context.read<AppState>().albums)
        if (!context.read<AppState>().isDeleting(a.id)) a
    ];
    if (albums.isEmpty) return _create();
    HapticFeedback.mediumImpact();
    final choice = await _MakeSheet.show(context);
    if (!mounted || choice == null) return;
    if (choice == _Make.album) return _create();
    final album = await _AlbumChooser.show(context, albums);
    if (!mounted || album == null) return;
    await _openAlbum(album, add: true);
  }

  @override
  Widget build(BuildContext context) {
    // Android back on another tab goes Home first, as a second press there
    // leaves the app
    return PopScope(
      canPop: _tab == HomeTab.home,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _select(HomeTab.home);
      },
      child: Scaffold(
        backgroundColor: Warm.ground,
        body: Stack(
          children: [
            IndexedStack(
              index: _tab.index,
              children: [
                // Rebuilt on each visit, so what was seen last time is gone
                if (_tab == HomeTab.home)
                  HomeScreen(
                    onOpenAlbum: _openAlbumById,
                    onRefresh: () => _refresh(context.read<AppState>()),
                  )
                else
                  const SizedBox.shrink(),
                ShelfScreen(
                  docked: true,
                  onOpenAlbum: _openAlbum,
                  onCreateAlbum: _create,
                  onOpenPeople: (album) => openAlbumPeople(context, album),
                ),
                // Rebuilt on each visit, so rosters and unread rows are fresh
                if (_tab == HomeTab.people)
                  const EveryoneTab()
                else
                  const SizedBox.shrink(),
                if (_tab == HomeTab.notifications)
                  NotificationsScreen(asTab: true, onOpenAlbum: _openAlbumById)
                else
                  const SizedBox.shrink(),
                ProfileScreen(
                  asTab: true,
                  onSafetyNumbers: () => _select(HomeTab.people),
                ),
              ],
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: TabDock(current: _tab, onSelect: _select, onMake: _make),
            ),
          ],
        ),
      ),
    );
  }
}

enum _Make { photos, album }

class _MakeSheet extends StatelessWidget {
  const _MakeSheet();

  static Future<_Make?> show(BuildContext context) =>
      showModalBottomSheet<_Make>(
        context: context,
        backgroundColor: Warm.ground,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
        builder: (_) => const _MakeSheet(),
      );

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Warm.pagePad, 26, Warm.pagePad, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Choice(
              icon: Icons.add_photo_alternate_outlined,
              title: 'Add photos',
              detail: 'To one of your albums',
              onTap: () => Navigator.of(context).pop(_Make.photos),
            ),
            const SizedBox(height: 10),
            _Choice(
              icon: Icons.photo_album_outlined,
              title: 'New album',
              detail: 'Start one and invite people',
              onTap: () => Navigator.of(context).pop(_Make.album),
            ),
          ],
        ),
      ),
    );
  }
}

// Most recent first, since that is usually where new photos belong
class _AlbumChooser extends StatelessWidget {
  final List<AlbumModel> albums;

  const _AlbumChooser({required this.albums});

  static Future<AlbumModel?> show(
      BuildContext context, List<AlbumModel> albums) {
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    final sorted = [...albums]..sort((a, b) =>
        (b.latestActivityAt ?? epoch).compareTo(a.latestActivityAt ?? epoch));
    return showModalBottomSheet<AlbumModel>(
      context: context,
      backgroundColor: Warm.ground,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (_) => _AlbumChooser(albums: sorted),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Watched so names and faces fill in as they decrypt
    final state = context.watch<AppState>();
    return ConstrainedBox(
      constraints:
          BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
      child: SafeArea(
        top: false,
        child: ListView(
          shrinkWrap: true,
          padding:
              const EdgeInsets.fromLTRB(Warm.pagePad, 26, Warm.pagePad, 18),
          children: [
            Text('Add photos to', style: Warm.pageTitle),
            const SizedBox(height: 18),
            for (final a in albums) ...[
              _albumChoice(context, state, a),
              const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  }

  // Who will see the photos matters as much as which album, so each card
  // carries the faces of the people it is shared with
  Widget _albumChoice(BuildContext context, AppState state, AlbumModel a) {
    final self = state.selfMemberToken(a.id) ?? a.memberToken;
    final others = [
      for (final m in a.memberPreviews)
        if (m.memberToken != self) m,
    ];
    final total = math.max(others.length, a.activeMemberCount - 1);
    String? nameOf(MemberPreview m) =>
        state.memberDisplayName(a.id, m.memberToken);
    final photos = '${a.mediaCount} photo${a.mediaCount == 1 ? '' : 's'}';
    return _Choice(
      leading: _Thumb(albumId: a.id),
      title: state.albumDisplayName(a.id) ?? 'Album',
      detail: '$photos · ${_sharedWith(others.map(nameOf).toList(), total)}',
      trailing: total == 0
          ? null
          : PrintFaces(
              albumId: a.id,
              members: others,
              total: total,
              nameOf: nameOf,
              ring: Warm.groundLift,
            ),
      onTap: () => Navigator.of(context).pop(a),
    );
  }

  // Names until they run long, then a count; never a token
  static String _sharedWith(List<String?> names, int total) {
    if (total == 0) return 'Only you';
    final known = names.nonNulls.toList();
    if (known.length == total && total == 1) return 'With ${known[0]}';
    if (known.length == total && total == 2) {
      return 'With ${known[0]} and ${known[1]}';
    }
    return 'With $total people';
  }
}

class _Choice extends StatelessWidget {
  final IconData? icon;
  // Takes the icon's place, as an album's photo does
  final Widget? leading;
  final String title;
  final String detail;
  // Takes the chevron's place
  final Widget? trailing;
  final VoidCallback onTap;

  const _Choice({
    this.icon,
    this.leading,
    required this.title,
    required this.detail,
    this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Warm.groundLift,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          child: Row(
            children: [
              leading ?? Icon(icon, size: 24, color: Warm.ink),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Warm.rowTitle),
                    const SizedBox(height: 3),
                    Text(detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Warm.rowValue),
                  ],
                ),
              ),
              if (trailing != null)
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: trailing,
                )
              else
                const Icon(Icons.chevron_right_rounded,
                    size: 22, color: Warm.inkFaint),
            ],
          ),
        ),
      ),
    );
  }
}

// An album's latest photo, so the list reads by picture and not by name alone
class _Thumb extends StatelessWidget {
  final String albumId;

  const _Thumb({required this.albumId});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox.square(
        dimension: 48,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(
              color: Warm.wellEmpty,
              child: Icon(Icons.photo_outlined, size: 20, color: Warm.inkGhost),
            ),
            AlbumCover(albumId: albumId),
          ],
        ),
      ),
    );
  }
}
