import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:miuchio/data/api/album_api.dart';
import 'package:miuchio/data/models/album_model.dart';
import 'package:miuchio/data/native/image_transcoder.dart';
import 'package:miuchio/data/storage/media_cache_manager.dart';
import 'package:miuchio/data/storage/picked_file.dart';
import 'package:miuchio/domain/albums/cover_setter.dart';
import 'package:miuchio/e2ee/cover_image.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/shelf/album_print.dart';
import 'package:miuchio/ui/shelf/still_print.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/grouped_list.dart';
import 'package:miuchio/ui/widgets/pressable_scale.dart';
import 'package:miuchio/ui/widgets/warm_button.dart';
import 'package:provider/provider.dart';

import 'album_copy.dart';
import 'cover_picker.dart';
import 'photo_sheets.dart';

enum _CoverSource { album, phone }

// Everything about one album in one place. Owners also choose the cover,
// rename and add people. Leaving or deleting closes this page first, since
// both end on the shelf
class AlbumSettingsScreen extends StatefulWidget {
  // Shown until the shelf listing has the album
  final AlbumModel album;
  final bool owner;
  final List<MediaRecord> photos;
  final AlbumService albumService;
  final VoidCallback onRename;
  final VoidCallback onPeople;
  final VoidCallback onAlbumInfo;
  // Null unless the viewer may invite
  final VoidCallback? onAddSomeone;
  final VoidCallback onLeaveOrDelete;

  const AlbumSettingsScreen({
    super.key,
    required this.album,
    required this.owner,
    required this.photos,
    required this.albumService,
    required this.onRename,
    required this.onPeople,
    required this.onAlbumInfo,
    required this.onLeaveOrDelete,
    this.onAddSomeone,
  });

  @override
  State<AlbumSettingsScreen> createState() => _AlbumSettingsScreenState();
}

class _AlbumSettingsScreenState extends State<AlbumSettingsScreen> {
  bool _busy = false;

  String get _id => widget.album.id;

  Future<void> _run(Future<void> Function() job) async {
    final messenger = ScaffoldMessenger.of(context);
    final state = context.read<AppState>();
    setState(() => _busy = true);
    try {
      await job();
      final fresh = await widget.albumService.getMyAlbums();
      if (fresh != null) state.applyListing(fresh);
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
        content: Text(AlbumCopy.coverFailed),
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleNewest(bool on) async {
    if (on) return _run(() => context.read<CoverSetter>().useNewest(_id));
    await _changeCover();
  }

  Future<void> _changeCover() async {
    final hasPhotos = widget.photos.any((r) => r.hasThumb);
    final source = await askChoice<_CoverSource>(
      context,
      title: AlbumCopy.changeCover,
      choices: [
        if (hasPhotos)
          const SheetChoice(_CoverSource.album, Icons.photo_library_outlined,
              AlbumCopy.coverFromAlbum),
        const SheetChoice(_CoverSource.phone,
            Icons.add_photo_alternate_outlined, AlbumCopy.coverFromPhone),
      ],
    );
    if (!mounted) return;
    switch (source) {
      case _CoverSource.album:
        await _fromAlbum();
      case _CoverSource.phone:
        await _fromPhone();
      case null:
        break;
    }
  }

  Future<void> _fromAlbum() async {
    final setter = context.read<CoverSetter>();
    final mediaId = await CoverPicker.show(
      context,
      photos: widget.photos,
      cache: context.read<MediaCacheManager>(),
      current: _album(context.read<AppState>()).cover?.mediaId,
    );
    if (mediaId == null || !mounted) return;
    await _run(() => setter.usePhoto(_id, mediaId));
  }

  // Cleaned of location and camera details before it is sealed
  Future<void> _fromPhone() async {
    final setter = context.read<CoverSetter>();
    final messenger = ScaffoldMessenger.of(context);
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;
    setState(() => _busy = true);
    Uint8List? jpeg;
    try {
      jpeg = await CoverImage.prepare(await picked.readAsBytes(),
          transcode: platformImageTranscoder);
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
        content: Text(AlbumCopy.coverUnusable),
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      unawaited(pickerCacheRoots()
          .then((roots) => discardPickedFile(picked.path, roots)));
      if (mounted) setState(() => _busy = false);
    }
    final ready = jpeg;
    if (ready == null || !mounted) return;
    await _run(() async {
      if (!await setter.useImage(_id, ready)) throw StateError('no album key');
    });
  }

  void _leaveOrDelete() {
    Navigator.of(context).pop();
    widget.onLeaveOrDelete();
  }

  AlbumModel _album(AppState state) =>
      state.albums.where((a) => a.id == _id).firstOrNull ?? widget.album;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final album = _album(state);
    // The roster may still be loading, the listing already knows the role
    final owner = widget.owner || album.myRole == 'admin';
    // Like uploads, a cover waits until the album's newest key is in place
    final locked = _busy ||
        album.rotationRequired ||
        state.keyBlockFor(album.id) != null;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Warm.overlayOnGround,
      child: Scaffold(
        backgroundColor: Warm.ground,
        body: SafeArea(
          bottom: false,
          child: ListView(
            physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics()),
            padding: const EdgeInsets.fromLTRB(
                Warm.pagePad - 8, 16, Warm.pagePad - 8, 48),
            children: [
              const Align(alignment: Alignment.centerLeft, child: WarmBack()),
              const SizedBox(height: 18),
              Center(
                child: SizedBox(
                  width: 220,
                  child: Opacity(
                    opacity: _busy ? 0.6 : 1,
                    child: StillPrint(album: album),
                  ),
                ),
              ),
              if (owner) ...[
                const SizedBox(height: 18),
                Center(child: _RenamePill(onTap: widget.onRename)),
              ],
              const SizedBox(height: 30),
              if (owner) ...[
                GroupCard(children: [
                  SettingsRow(
                    lead: SettingsRow.icon(Icons.photo_outlined),
                    title: AlbumCopy.coverNewest,
                    trailing: Switch.adaptive(
                      value: album.cover == null,
                      activeTrackColor: Warm.ink,
                      onChanged: locked ? null : _toggleNewest,
                    ),
                  ),
                  if (album.cover != null)
                    SettingsRow(
                      lead: SettingsRow.icon(Icons.swap_horiz_rounded),
                      title: AlbumCopy.changeCover,
                      onTap: locked ? null : _changeCover,
                    ),
                ]),
                const SizedBox(height: 18),
              ],
              GroupCard(children: [
                if (widget.onAddSomeone != null)
                  SettingsRow(
                    lead: SettingsRow.icon(Icons.person_add_alt_rounded),
                    title: AlbumCopy.addSomeone,
                    onTap: widget.onAddSomeone,
                  ),
                _PeopleRow(album: album, onTap: widget.onPeople),
              ]),
              const SizedBox(height: 18),
              GroupCard(children: [
                SettingsRow(
                  lead: SettingsRow.icon(Icons.info_outline_rounded),
                  title: AlbumCopy.albumInfo,
                  onTap: widget.onAlbumInfo,
                ),
              ]),
              const SizedBox(height: 18),
              GroupCard(children: [
                SettingsRow(
                  lead: SettingsRow.icon(
                      owner
                          ? Icons.delete_outline_rounded
                          : Icons.logout_rounded,
                      warn: true),
                  title: owner ? AlbumCopy.deleteAlbum : AlbumCopy.leaveAlbum,
                  warn: true,
                  trailing: const SizedBox.shrink(),
                  onTap: _leaveOrDelete,
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class _RenamePill extends StatelessWidget {
  final VoidCallback onTap;

  const _RenamePill({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: AlbumCopy.renameAlbum,
      excludeSemantics: true,
      child: PressableScale(
        onTap: onTap,
        child: Container(
          key: const Key('album-settings-rename'),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Warm.groundLift,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.edit_outlined, size: 15, color: Warm.inkSoft),
              const SizedBox(width: 7),
              Text(AlbumCopy.renameAlbum, style: Warm.rowTitle),
            ],
          ),
        ),
      ),
    );
  }
}

// Faces stacked side by side and a count, so the card never grows with the
// album. The full list is one tap away
class _PeopleRow extends StatelessWidget {
  final AlbumModel album;
  final VoidCallback onTap;

  const _PeopleRow({required this.album, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    return Semantics(
      button: true,
      label: '${AlbumCopy.people}, '
          '${AlbumCopy.peopleCount(album.activeMemberCount)}',
      excludeSemantics: true,
      child: GestureDetector(
        key: const Key('album-settings-people'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          height: 56,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(kRowPad, 0, 12, 0),
            child: Row(
              children: [
                PrintFaces(
                  albumId: album.id,
                  members: album.memberPreviews,
                  total: album.activeMemberCount,
                  nameOf: (m) => m.memberToken == album.memberToken
                      ? state.profileName
                      : state.memberDisplayName(album.id, m.memberToken),
                  ring: Warm.groundLift,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    AlbumCopy.peopleCount(album.activeMemberCount),
                    style: Warm.rowTitle,
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    size: 17, color: Warm.inkGhost),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
