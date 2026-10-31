import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:miuchio/data/api/album_api.dart';
import 'package:miuchio/data/api/media_api.dart';
import 'package:miuchio/data/storage/media_cache_manager.dart';
import 'package:miuchio/data/storage/media_catalog.dart';
import 'package:miuchio/data/storage/name_cache.dart';
import 'package:miuchio/domain/upload/upload_ports.dart';
import 'package:miuchio/crypto/uuid_bytes.dart';
import 'package:miuchio/ui/album/add_people_sheet.dart';
import 'package:miuchio/ui/album/album_banners.dart';
import 'package:miuchio/ui/album/album_media_grid.dart';
import 'package:miuchio/ui/album/album_copy.dart';
import 'package:miuchio/ui/album/album_foot.dart';
import 'package:miuchio/ui/album/album_header.dart';
import 'package:miuchio/ui/album/album_info_screen.dart';
import 'package:miuchio/ui/album/album_settings_screen.dart';
import 'package:miuchio/ui/widgets/encrypted_thumbnail.dart';
import 'package:miuchio/ui/album/album_rename.dart';
import 'package:miuchio/ui/album/album_stats.dart';
import 'package:miuchio/ui/album/member_avatars.dart';
import 'package:miuchio/ui/album/photo_delete.dart';
import 'package:miuchio/ui/album/photo_sheets.dart';
import 'package:miuchio/ui/album/photo_peek.dart';
import 'package:miuchio/ui/album/photo_select.dart';
import 'package:miuchio/ui/providers/latest_only.dart';
import 'package:miuchio/ui/providers/upload_queue_model.dart';
import 'package:miuchio/ui/widgets/upload_pill.dart';
import 'package:miuchio/ui/widgets/upload_sheet.dart';
import 'package:miuchio/data/models/album_model.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/data/models/member_model.dart';
import 'package:miuchio/diagnostics/trace.dart';
import 'package:miuchio/e2ee/album_keys.dart';
import 'package:miuchio/e2ee/epoch_processor.dart';
import 'package:miuchio/e2ee/identity_trust.dart';
import 'package:miuchio/e2ee/invite.dart';
import 'package:miuchio/e2ee/member_removal.dart';
import 'package:miuchio/e2ee/rotation_recovery.dart';
import 'package:miuchio/e2ee/sealed_name.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/shelf/shelf_data.dart';
import 'package:miuchio/ui/screens/photo_viewer_screen.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/member_face.dart';
import 'package:miuchio/ui/widgets/decrypted_image_preview.dart';
import 'package:miuchio/ui/widgets/encrypted_image.dart';
import 'package:miuchio/ui/widgets/safety_number_sheet.dart';
import 'package:miuchio/ui/people/album_people.dart';
import 'package:miuchio/ui/people/trust_summary.dart';
import 'package:miuchio/ui/navigation/screen_route.dart';

Future<List<XFile>> _systemPicker({int limit = 0}) =>
    ImagePicker().pickMultiImage(limit: limit);

typedef MultiImagePicker = Future<List<XFile>> Function({int limit});

class AlbumDetailScreen extends StatefulWidget {
  final AlbumModel album;
  final AlbumService albumService;
  final MediaApi? mediaApi;
  final MultiImagePicker? pickImages;
  // Opens the photo picker as soon as the album can take uploads
  final bool addOnOpen;

  AlbumDetailScreen({
    super.key,
    required this.album,
    AlbumService? albumService,
    this.mediaApi,
    this.pickImages,
    this.addOnOpen = false,
  }) : albumService = albumService ?? AlbumService();

  @override
  State<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends State<AlbumDetailScreen> {
  late final MediaApi _media;
  List<AlbumMember> _members = [];
  List<MediaRecord> _items = [];
  AlbumFeedState _feed = AlbumFeedState.loadingNoCache;
  bool _markedOpenSeen = false;
  late bool _addPending = widget.addOnOpen;

  // Deduplicate events repeated by unrelated AppState notifications
  String? _lastSeenMediaAddedId;
  int _lastSeenMemberTick = 0;
  int _lastSeenMediaRemovedTick = 0;
  // Prevent access loss notifications from popping the route twice
  bool _accessLost = false;
  AppState? _appState;

  // One trace ID covers local load, refresh, and first paint
  late final String _openTraceId = Trace.newTraceId();
  final Stopwatch _openClock = Stopwatch()..start();
  bool _firstThumbnailReported = false;
  String _renderSource = 'none';

  MediaCatalog? _catalog;

  final ScrollController _scroll = ScrollController();
  bool _collapsed = false;
  String? _filterToken;
  final PhotoSelection _selection = PhotoSelection();

  @override
  void initState() {
    super.initState();
    // The app owns the shared MediaApi so an upload survives this screen
    _media = widget.mediaApi ?? context.read<MediaApi>();
    Trace.event('album.open', fields: {
      'album': Trace.id(widget.album.id),
      'tid': _openTraceId,
      'gen': widget.album.mediaGeneration,
    });
    try {
      _catalog = context.read<MediaCatalog>();
    } catch (_) {
      _catalog = null;
    }
    _scroll.addListener(_onScroll);
    _loadMembers();
    _openLocalFirst();
  }

  void _onScroll() {
    final past = _scroll.hasClients && _scroll.offset > 96;
    if (past != _collapsed) setState(() => _collapsed = past);
  }

  void _toggleFilter(String token) =>
      setState(() => _filterToken = _filterToken == token ? null : token);

  AlbumMember? get _owner =>
      _members.where((m) => m.role == 'admin' && !m.revoked).firstOrNull;

  Future<void> _leave() async {
    final albumId = uuidToBytes(widget.album.id);
    final myToken = widget.album.memberToken;
    if (albumId == null || myToken == null) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final removal = context.read<MemberRemovalCoordinator>();
    final deletePhotos = await confirmLeave(context,
        deletePhotos: context.read<AppState>().deleteMediaOnLeave);
    if (deletePhotos == null) return;
    // We pop ourselves, so the removal notice must not pop again
    _accessLost = true;
    try {
      await removal.leave(albumId, base64.decode(base64.normalize(myToken)),
          deleteMedia: deletePhotos);
    } on MemberRemovalException {
      _accessLost = false;
      messenger.showSnackBar(_note(AlbumCopy.leaveFailed));
      return;
    } catch (_) {
      // The server already let us go, a failed local wipe is retried by cleanup
    }
    if (mounted) navigator.pop();
  }

  Future<void> _deleteAlbum() async {
    final albumId = uuidToBytes(widget.album.id);
    if (albumId == null) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final removal = context.read<MemberRemovalCoordinator>();
    final appState = context.read<AppState>();
    if (!await confirmSheet(
      context,
      key: 'album-delete',
      title: AlbumCopy.deleteAlbumTitle,
      body: AlbumCopy.deleteAlbumBody,
      confirm: AlbumCopy.deleteForEveryone,
      cancel: AlbumCopy.deleteCancel,
    )) {
      return;
    }
    // Leave at once, the shelf hides the album until the server answers
    _accessLost = true;
    appState.setDeleting(widget.album.id, true);
    navigator.pop();
    messenger.showSnackBar(_note(AlbumCopy.deletingAlbum, brief: true));
    if (!await widget.albumService.deleteAlbum(widget.album.id)) {
      appState.setDeleting(widget.album.id, false);
      messenger.showSnackBar(_note(AlbumCopy.deleteAlbumFailed));
      return;
    }
    try {
      await removal.onSelfRemoved(albumId);
    } catch (_) {
      // The album is gone on the server, a failed local wipe is retried by cleanup
    }
    appState.setDeleting(widget.album.id, false);
  }

  Future<void> _removeMember(AlbumMember m, {required bool invited}) async {
    final albumId = uuidToBytes(widget.album.id);
    if (albumId == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final removal = context.read<MemberRemovalCoordinator>();
    if (!await confirmSheet(
      context,
      key: 'member-remove',
      title: invited
          ? AlbumCopy.cancelInviteTitle
          : AlbumCopy.removeTitle(_memberName(m)),
      body: invited ? AlbumCopy.cancelInviteBody : AlbumCopy.removeBody,
      confirm: invited ? AlbumCopy.cancelInvite : AlbumCopy.remove,
      cancel: AlbumCopy.deleteCancel,
    )) {
      return;
    }
    try {
      await removal.kick(
          albumId, base64.decode(base64.normalize(m.memberToken)));
    } on MemberRemovalException {
      messenger.showSnackBar(_note(AlbumCopy.removeFailed));
      return;
    } catch (_) {
      // Revoked already, rotation recovery finishes the key change
    }
    if (mounted) await _loadMembers();
  }

  Future<void> _openSettings() async {
    final state = context.read<AppState>();
    MediaCacheManager? cache;
    try {
      cache = context.read<MediaCacheManager>();
    } catch (_) {
      cache = null;
    }
    Widget thumb(MediaRecord r) => cache == null
        ? const SizedBox.shrink()
        : EncryptedThumbnail(record: r, cache: cache, fit: BoxFit.cover);
    final current = state.albums
        .where((a) => a.id == widget.album.id)
        .firstOrNull
        ?.coverMediaId;
    final exit =
        await Navigator.of(context).push(screenRoute<AlbumInfoExit>(
      AlbumSettingsScreen(
        name: () => state.albumDisplayName(widget.album.id) ?? 'Album',
        photos: _visible,
        coverId: current,
        thumb: thumb,
        onChangeCover: (was) => _chooseCover(was, thumb),
        onRename: _rename,
        load: () async => _managed(),
        onAdd: _openAddMember,
        onRemove: (p) async {
          final m = _members.where((m) => m.memberToken == p.id).firstOrNull;
          if (m != null) await _removeMember(m, invited: p.invited);
        },
        onOpen: (p) async {
          final m = _members.where((m) => m.memberToken == p.id).firstOrNull;
          if (m != null) await _openPerson(m);
        },
        onInfo: _openAlbumInfo,
        onDelete: () => Navigator.of(context).pop(AlbumInfoExit.delete),
      ),
    ));
    if (exit == AlbumInfoExit.delete && mounted) await _deleteAlbum();
  }

  // Returns the cover in use afterwards, which is the old one on failure
  Future<String?> _chooseCover(
      String? was, Widget Function(MediaRecord) thumb) async {
    final picked = await CoverPickerScreen.show(context,
        photos: _visible, current: was, thumb: thumb);
    if (picked == null || picked.id == was || !mounted) return was;
    final messenger = ScaffoldMessenger.of(context);
    final state = context.read<AppState>();
    if (!await widget.albumService.setCover(widget.album.id, picked.id)) {
      messenger.showSnackBar(_note(AlbumCopy.coverFailed));
      return was;
    }
    state.refreshSummarySoon();
    return picked.id;
  }

  List<ManagedPerson> _managed() {
    final names = _resolvedNames();
    final self = widget.album.memberToken;
    final me = context.read<AppState>().profileName.trim();
    return [
      for (final m in _members)
        if (!m.revoked)
          if (m.memberToken != self && m.profile.nameCt == null)
            ManagedPerson(
              id: m.memberToken,
              name: AlbumCopy.invitedShort,
              face: const SizedBox(),
              invited: true,
            )
          else
            ManagedPerson(
              id: m.memberToken,
              name: m.memberToken == self
                  ? (me.isEmpty ? AlbumCopy.you : me)
                  : names[m.memberToken] ?? AlbumCopy.unknownMember,
              face: _face(m.memberToken, names[m.memberToken], 40),
              owner: m.role == 'admin',
              self: m.memberToken == self,
            ),
    ];
  }

  Future<void> _openPerson(AlbumMember m) async {
    final album = ModalRoute.of(context);
    final name = _resolvedNames()[m.memberToken];
    final action = await showPersonSheet(
      context,
      face: _face(m.memberToken, name, 46),
      name: name,
      owner: m.role == 'admin',
      canVerify: _peerIk(m) != null,
      // The creator can't be removed, they delete the album instead
      canRemove: _viewerIsAdmin && m.role != 'admin',
    );
    if (!mounted) return;
    switch (action) {
      case PersonAction.photos:
        Navigator.of(context).popUntil((r) => r == album);
        setState(() => _filterToken = m.memberToken);
      case PersonAction.safetyNumber:
        await _openSafetyNumber(m);
      case PersonAction.remove:
        await _removeMember(m, invited: false);
      case null:
        break;
    }
  }

  Widget _face(String token, String? name, double size) => MemberFace(
        albumId: widget.album.id,
        token: token,
        name: name,
        size: size,
        style: Warm.acFace.copyWith(fontSize: size * 0.36),
      );

  Future<void> _rename() async {
    final messenger = ScaffoldMessenger.of(context);
    final done = await renameAlbum(context,
        albumId: widget.album.id, albumService: widget.albumService);
    if (done == false) messenger.showSnackBar(_note(AlbumCopy.renameFailed));
  }

  Future<void> _openAlbumInfo() async {
    final names = <String, String>{};
    for (final m in _members) {
      final e = _memberNames[m.memberToken];
      if (e != null && e.ct == m.profile.nameCt) names[m.memberToken] = e.name;
    }
    final people = _members.where((m) => !m.revoked).length;
    final owner = _owner;
    if (!mounted) return;
    final exit =
        await Navigator.of(context).push(screenRoute<AlbumInfoExit>(
      AlbumInfoScreen(
        albumId: widget.album.id,
        albumName: _appState?.albumDisplayName(widget.album.id) ?? 'Album',
        createdAt: widget.album.createdAt,
        stats: AlbumStats.of(_visible, peopleCount: people),
        nameOf: (token) => names[token],
        madeBy: owner == null
            ? null
            : owner.memberToken == widget.album.memberToken
                ? AlbumCopy.madeByYou
                : names[owner.memberToken],
        people: [
          for (final m in _members)
            if (!m.revoked)
              InfoPerson(
                token: m.memberToken,
                name: m.memberToken == widget.album.memberToken
                    ? names[m.memberToken] ??
                        context.read<AppState>().profileName
                    : names[m.memberToken],
                owner: m.role == 'admin',
                self: m.memberToken == widget.album.memberToken,
                invited: m.memberToken != widget.album.memberToken &&
                    m.profile.nameCt == null,
              ),
        ],
        onOpenPerson: (token) {
          final m = _members.where((m) => m.memberToken == token).firstOrNull;
          if (m != null) _openPerson(m);
        },
        // The owner deletes from settings, everyone else leaves from here
        exit: _viewerIsAdmin || _me == null ? null : AlbumInfoExit.leave,
      ),
    ));
    if (!mounted) return;
    switch (exit) {
      case AlbumInfoExit.leave:
        await _leave();
      case AlbumInfoExit.delete:
        await _deleteAlbum();
      case null:
        break;
    }
  }

  Future<void> _openPeek(
    MediaRecord record,
    DecryptedImagePreview preview,
    ImageProvider onScreen,
  ) async {
    final shown = Trace.start('peek.photoFrame');
    final cache = context.read<MediaCacheManager>();
    final name = _memberNames[record.uploaderToken];
    final resolved = _members
        .where((m) => m.memberToken == record.uploaderToken)
        .map((m) =>
            name != null && name.ct == m.profile.nameCt ? name.name : null)
        .firstOrNull;
    await PhotoPeek.show(
      context,
      record: record,
      uploaderName: resolved,
      uploaderFace: _face(record.uploaderToken, resolved, 20),
      isOwner: record.uploaderToken == widget.album.memberToken,
      onDelete: () => _deleteMedia(record),
      aspectRatio: preview.aspectRatio,
      previewBuilder: (_) => Image.memory(
        preview.bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        frameBuilder: (_, child, frame, sync) {
          if (frame != null) {
            shown.end(fields: {'sync': sync});
            return child;
          }
          return Image(
            image: onScreen,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            frameBuilder: (_, child, frame, sync) {
              if (frame != null) {
                shown.end(fields: {'sync': sync, 'grid': true});
              }
              return child;
            },
          );
        },
      ),
      fullImageBuilder: (_, cacheWidth, cacheHeight, onReady) => EncryptedImage(
          record: record,
          cache: cache,
          fit: BoxFit.cover,
          cacheWidth: cacheWidth,
          cacheHeight: cacheHeight,
          onFirstFrame: onReady),
    );
  }

  String? _uploaderName(String token) {
    final name = _memberNames[token];
    return _members
        .where((m) => m.memberToken == token)
        .map((m) =>
            name != null && name.ct == m.profile.nameCt ? name.name : null)
        .firstOrNull;
  }

  Future<void> _openViewer(MediaRecord record) async {
    final records = _shown;
    final index = records.indexWhere((r) => r.id == record.id);
    if (index < 0) return;
    await Navigator.of(context).push(screenRoute<void>(
      PhotoViewerScreen(
        records: records,
        initialIndex: index,
        cache: context.read<MediaCacheManager>(),
        nameOf: _uploaderName,
        faceOf: (token, size) => _face(token, _uploaderName(token), size),
        isOwner: (r) => r.uploaderToken == widget.album.memberToken,
        onDelete: _deleteFromViewer,
      ),
    ));
  }

  Future<bool> _deleteFromViewer(MediaRecord record) => _deletePhoto(record);

  bool _isMine(MediaRecord r) {
    final me = widget.album.memberToken;
    return me != null && r.uploaderToken == me;
  }

  List<MediaRecord> get _shown => _filterToken == null
      ? _visible
      : _visible.where((r) => r.uploaderToken == _filterToken).toList();

  // Photos hidden by a filter or a delete never count
  (List<MediaRecord>, List<MediaRecord>) _picked(List<MediaRecord> shown) {
    final picked = [
      for (final r in shown)
        if (_selection.contains(r.id)) r
    ];
    return (picked, picked.where(_isMine).toList());
  }

  // Others' photos in the selection are skipped, never sent to the server
  Future<void> _deleteSelected(List<MediaRecord> mine, int count) async {
    final ok = await confirmSheet(
      context,
      key: 'select-delete',
      title: AlbumCopy.deleteManyTitle(count, mine.length),
      body: AlbumCopy.deleteManyBody(count, mine.length),
      confirm: AlbumCopy.deleteForEveryone,
      cancel: AlbumCopy.deleteCancel,
    );
    if (!ok || !mounted) return;
    _selection.end();
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    MediaCacheManager? cache;
    try {
      cache = context.read<MediaCacheManager>();
    } catch (_) {}
    for (final r in mine) {
      app.hideMedia(widget.album.id, r.id);
    }
    messenger.showSnackBar(
        _note(AlbumCopy.deletingPhotos(mine.length), brief: true));
    // A few requests at a time, so a large selection doesn't flood the server
    var next = 0;
    var failed = 0;
    Future<void> worker() async {
      while (next < mine.length) {
        final done = await deletePhoto(
          app: app,
          media: _media,
          cache: cache,
          albumId: widget.album.id,
          record: mine[next++],
        );
        if (!done) failed++;
      }
    }

    await Future.wait(
        [for (var i = 0; i < 4 && i < mine.length; i++) worker()]);
    if (failed > 0) {
      messenger.showSnackBar(_note(AlbumCopy.deleteManyFailed(failed)));
    }
    if (mounted) unawaited(_loadMedia());
  }

  Future<void> _deleteMedia(MediaRecord record) async {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
    await _deletePhoto(record);
  }

  // Hidden before the request, so the grid answers at once
  Future<bool> _deletePhoto(MediaRecord record) async {
    final messenger = ScaffoldMessenger.of(context);
    MediaCacheManager? cache;
    try {
      cache = context.read<MediaCacheManager>();
    } catch (_) {}
    final done = deletePhoto(
      app: context.read<AppState>(),
      media: _media,
      cache: cache,
      albumId: widget.album.id,
      record: record,
    );
    messenger.showSnackBar(_note(AlbumCopy.deletingPhoto, brief: true));
    if (!await done) {
      messenger.showSnackBar(_note(AlbumCopy.deleteFailed));
      return false;
    }
    if (mounted) unawaited(_loadMedia());
    return true;
  }

  // Hidden deletes stay in _items, so a refused one returns in album order
  List<MediaRecord> get _visible {
    final app = _appState;
    if (app == null) return _items;
    final id = widget.album.id;
    return _items.where((r) => !app.hidesMedia(id, r.id)).toList();
  }

  Future<void> _openLocalFirst() async {
    await _loadLocal();
    await _loadMedia();
  }

  Future<void> _loadLocal() async {
    final cache = _catalog;
    if (cache == null) return;
    final span = Trace.start('album.loadLocal',
        traceId: _openTraceId, fields: {'album': Trace.id(widget.album.id)});
    try {
      final local = await cache.listRecordsForAlbum(widget.album.id);
      span.end(fields: {'n': local.length});
      if (!mounted || local.isEmpty) return;
      setState(() {
        _items = local;
        _renderSource = 'local';
        _feed = AlbumFeedState.refreshing;
      });
    } catch (e) {
      span.fail(Trace.reasonOf(e));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = context.read<AppState>();
    if (!identical(_appState, next)) {
      _appState?.removeListener(_onAppStateChange);
      _appState = next;
      _appState!.addListener(_onAppStateChange);
    }
    final queue = context.read<UploadQueueModel>();
    if (!identical(_uploads, queue)) {
      _uploads?.removeListener(_onUploadChange);
      _uploads?.stopObserving(widget.album.id);
      _uploads = queue;
      queue.addListener(_onUploadChange);
      queue.observeAlbum(widget.album.id);
    }
    if (!_markedOpenSeen) {
      _markedOpenSeen = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_markSeen(_currentMediaGeneration()));
      });
    }
  }

  int _currentMediaGeneration() {
    final state = _appState;
    if (state == null) return widget.album.mediaGeneration;
    for (final album in state.albums) {
      if (album.id == widget.album.id) return album.mediaGeneration;
    }
    return widget.album.mediaGeneration;
  }

  void _onAppStateChange() {
    final s = _appState;
    if (s == null) return;

    if (!_accessLost && s.lastRemovedAlbumId == widget.album.id) {
      _accessLost = true;
      final nav = Navigator.of(context);
      final messenger = ScaffoldMessenger.of(context);
      if (nav.canPop()) nav.pop();
      messenger.showSnackBar(_note(s.wasDeleted(widget.album.id)
          ? 'This album was deleted'
          : 'You were removed from this album'));
      return;
    }

    if (s.lastMediaRemovedAlbumId == widget.album.id &&
        s.mediaRemovedTick != _lastSeenMediaRemovedTick) {
      _lastSeenMediaRemovedTick = s.mediaRemovedTick;
      _loadMedia();
    }

    if (s.lastMemberChangedAlbumId == widget.album.id &&
        s.memberChangeTick != _lastSeenMemberTick) {
      _lastSeenMemberTick = s.memberChangeTick;
      _loadMembers();
    }

    if (s.lastMediaAddedAlbumId == widget.album.id) {
      final mid = s.lastMediaAddedMediaId;
      if (mid != null && mid != _lastSeenMediaAddedId) {
        _lastSeenMediaAddedId = mid;
        _loadMedia(markSeenThrough: _currentMediaGeneration());
      }
    }
  }

  // Ciphertext fingerprints prevent stale decrypted names after a rename
  final Map<String, ({String name, String ct})> _memberNames = {};

  // Use a neutral fallback while a renamed member's name is unresolved
  String _memberName(AlbumMember m) {
    final e = _memberNames[m.memberToken];
    if (e != null && e.ct == m.profile.nameCt) return e.name;
    return 'Member';
  }

  Future<void> _loadMembers() async {
    final members = await Trace.withId(
      _openTraceId,
      () => Trace.measure<List<AlbumMember>>(
        'album.loadMembers',
        () => widget.albumService.listMembers(widget.album.id),
        fields: {'album': Trace.id(widget.album.id)},
        endFields: (result) => {'n': result.length},
      ),
    );
    if (mounted) {
      setState(() {
        _members = members;
        // A removed member's filter has no avatar left to clear it
        if (_filterToken != null &&
            !members.any((m) => !m.revoked && m.memberToken == _filterToken)) {
          _filterToken = null;
        }
      });
      unawaited(_resolveMemberNames(members));
      unawaited(_reconcileTrust(members));
    }
  }

  // Display trust is separate from epoch signing authority and install blocks
  Map<String, TrustState> _trust = {};
  // Hides the header's security line until the first reconcile, so it never
  // claims nobody is verified while trust is still loading
  bool _trustReady = false;

  // Seen persistence must not fail a successful listing
  Future<void> _markSeen(int generation) async {
    try {
      await _seenStore()?.markSeen(widget.album.id, generation);
    } catch (_) {}
  }

  SeenStore? _seenStore() {
    try {
      return context.read<SeenStore>();
    } catch (_) {
      return null;
    }
  }

  IdentityTrust? _trustSvc() {
    try {
      return context.read<IdentityTrust>();
    } catch (_) {
      return null;
    }
  }

  Uint8List? _peerIk(AlbumMember m) {
    final b64 = m.profile.ikPub;
    if (b64 == null || b64.isEmpty) return null;
    try {
      final ik = base64.decode(base64.normalize(b64));
      return ik.length == 32 ? ik : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _reconcileTrust(List<AlbumMember> members) async {
    final trust = _trustSvc();
    final albumIdBytes = uuidToBytes(widget.album.id);
    if (trust == null || albumIdBytes == null) return;

    final peers = <PeerIdentity>[];
    for (final m in members) {
      if (m.revoked) continue;
      final ik = _peerIk(m);
      if (ik == null) continue;
      peers.add(PeerIdentity(memberToken: m.memberToken, ikPub: ik));
    }
    if (peers.isEmpty) {
      if (mounted) setState(() => _trustReady = true);
      return;
    }

    try {
      final states = await trust.reconcile(albumIdBytes, peers,
          myMemberToken: widget.album.memberToken);
      if (mounted && !_accessLost) {
        setState(() {
          _trust = states;
          _trustReady = true;
        });
      }
      // Fresh roster pins may be what a failed rotation was missing
      if (mounted &&
          _appState?.rotationFor(widget.album.id)?.failure ==
              RotationFailure.identityUnconfirmed) {
        unawaited(_retryRotation());
      }
    } catch (_) {
      // Trust display failures must not prevent viewing the album
    }
  }

  Future<void> _openSafetyNumber(AlbumMember m) async {
    final trust = _trustSvc();
    final albumIdBytes = uuidToBytes(widget.album.id);
    final ik = _peerIk(m);
    if (trust == null || albumIdBytes == null || ik == null) return;

    final state = _trust[m.memberToken] ?? TrustState.unverified;
    final digits =
        await trust.safetyNumber(albumId: albumIdBytes, peerIkPub: ik);
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Warm.ground,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (_) => SafetyNumberSheet(
        displayName: _memberName(m),
        digits: digits,
        state: state,
        albumName: _appState?.albumDisplayName(widget.album.id),
        face: _face(m.memberToken, _resolvedNames()[m.memberToken], 46),
        // Bind verification to the displayed key even if the roster changes
        onVerify: () async {
          await trust.markVerified(
              albumId: albumIdBytes, memberToken: m.memberToken, peerIkPub: ik);
          await _reconcileTrust(_members);
        },
      ),
    );
  }

  Future<void> _retryKeySync() async {
    final albumIdBytes = uuidToBytes(widget.album.id);
    if (albumIdBytes == null) return;
    EpochProcessor proc;
    try {
      proc = context.read<EpochProcessor>();
    } catch (_) {
      return;
    }
    await proc.catchUpAll([albumIdBytes]);
  }

  // Compare the failed install's signer key to prevent roster substitution
  Future<void> _verifyBlockingSigner(EpochBlocked block) async {
    final trust = _trustSvc();
    final albumIdBytes = uuidToBytes(widget.album.id);
    final ik = block.presentedIk;
    final token = block.senderToken;
    if (trust == null || albumIdBytes == null || ik == null || token == null) {
      return;
    }
    final tokenB64 = base64.encode(token);
    final name = _members
        .where((m) => m.memberToken == tokenB64)
        .map(_memberName)
        .firstOrNull;
    final digits =
        await trust.safetyNumber(albumId: albumIdBytes, peerIkPub: ik);
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Warm.ground,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafetyNumberSheet(
        displayName: name ?? 'this member',
        digits: digits,
        state: TrustState.changed,
        albumName: _appState?.albumDisplayName(widget.album.id),
        onVerify: () async {
          await trust.markVerified(
              albumId: albumIdBytes, memberToken: tokenB64, peerIkPub: ik);
          // Verification permits a retry but only a successful install clears the block
          unawaited(_retryKeySync());
        },
      ),
    );
  }

  Future<void> _resolveMemberNames(List<AlbumMember> members) async {
    if (!mounted) return;
    final withCt =
        members.where((m) => (m.profile.nameCt ?? '').isNotEmpty).toList();
    if (withCt.isEmpty) return;
    final nameCache = context.read<NameCache>();
    final albumId = widget.album.id;

    // Batch cache misses to share one MK unwrap per epoch
    final fromCache = <String, ({String name, String ct})>{};
    final misses = <({String token, Uint8List tokenBytes, String nameCt})>[];
    for (final m in withCt) {
      final ct = m.profile.nameCt!;
      final cached =
          nameCache.get(NameCache.memberKey(albumId, m.memberToken), ct);
      if (cached != null) {
        fromCache[m.memberToken] = (name: cached, ct: ct);
        continue;
      }
      final Uint8List tokenBytes;
      try {
        tokenBytes = base64.decode(base64.normalize(m.memberToken));
      } catch (_) {
        continue;
      }
      misses.add((token: m.memberToken, tokenBytes: tokenBytes, nameCt: ct));
    }
    if (fromCache.isNotEmpty && mounted) {
      setState(() => _memberNames.addAll(fromCache));
    }
    if (misses.isEmpty) return;

    final albumIdBytes = uuidToBytes(albumId);
    if (albumIdBytes == null) return;
    final ks = context.read<AlbumKeyStore>();
    final resolved = await SealedName.openMemberNames(ks, albumIdBytes, misses);
    // An album wipe may finish during decryption, so reject late results
    if (!mounted || _accessLost) return;
    if (resolved.isEmpty) return;
    final ctByToken = {for (final m in misses) m.token: m.nameCt};
    final applied = <String, ({String name, String ct})>{};
    resolved.forEach((token, name) {
      final ct = ctByToken[token];
      if (ct == null) return;
      nameCache.put(NameCache.memberKey(albumId, token), name, ct);
      applied[token] = (name: name, ct: ct);
    });
    if (mounted && applied.isNotEmpty) {
      setState(() => _memberNames.addAll(applied));
    }
  }

  // Joined people with a key to compare, never yourself or an invite
  TrustSummary? get _trustSummary {
    if (!_trustReady) return null;
    final self = widget.album.memberToken;
    return TrustSummary.of([
      for (final m in _members)
        if (!m.revoked &&
            m.memberToken != self &&
            m.profile.nameCt != null &&
            _peerIk(m) != null)
          (
            name: _memberName(m),
            trust: _trust[m.memberToken] ?? TrustState.unverified,
          ),
    ]);
  }

  // The album's own people, so the codes shown are this album's
  Future<void> _openSecurity() async {
    await openAlbumPeople(context, widget.album, service: widget.albumService);
    // Verifying or inviting there changes what this header shows
    if (mounted) await _loadMembers();
  }

  // Surfaced as a banner so a substituted key is noticed without tapping a chip
  List<AlbumMember> get _changedKeyMembers => _members
      .where((m) => !m.revoked && _trust[m.memberToken] == TrustState.changed)
      .toList();

  AlbumMember? get _me {
    final myToken = widget.album.memberToken;
    if (myToken == null) return null;
    for (final m in _members) {
      if (m.memberToken == myToken) return m;
    }
    return null;
  }

  // The co admin role is dormant and grants nothing
  bool get _viewerIsAdmin => _me?.role == 'admin';

  Future<void> _retryRotation() async {
    final albumIdBytes = uuidToBytes(widget.album.id);
    if (albumIdBytes == null) return;
    RotationRecoveryScheduler scheduler;
    try {
      scheduler = context.read<RotationRecoveryScheduler>();
    } catch (_) {
      return;
    }
    await scheduler.request(albumIdBytes);
  }

  Future<void> _openAddMember() async {
    final albumIdBytes = uuidToBytes(widget.album.id);
    if (albumIdBytes == null) return;
    final initiator = context.read<InviteInitiator>();
    final state = context.read<AppState>();
    final added = await AddPeopleSheet.show(
      context,
      albumId: widget.album.id,
      albumTitle: state.albumDisplayName(widget.album.id) ?? 'this album',
      members: [
        for (final a in _avatars())
          if (!a.pending) a
      ],
      myMiuchioId: state.miuchioId,
      onInvite: (miuchioId) => initiator.inviteExistingUser(
          miuchioId: miuchioId, albumId: albumIdBytes),
    );
    if (added && mounted) await _loadMembers();
  }

  Map<String, String> _resolvedNames() => {
        for (final m in _members)
          if (_memberNames[m.memberToken] case final e?
              when e.ct == m.profile.nameCt)
            m.memberToken: e.name,
      };

  // A member who has not published a name has not opened the album yet
  List<AvatarMember> _avatars() {
    final names = _resolvedNames();
    return [
      for (final m in _members)
        if (!m.revoked)
          AvatarMember(
            token: m.memberToken,
            name: names[m.memberToken],
            pending: m.profile.nameCt == null &&
                m.memberToken != widget.album.memberToken,
            self: m.memberToken == widget.album.memberToken,
            verified: _trust[m.memberToken] == TrustState.verified,
          ),
    ];
  }

  List<AvatarMember> _previewAvatars(AppState state) => [
        for (final m in widget.album.memberPreviews)
          AvatarMember(
            token: m.memberToken,
            name: state.memberDisplayName(widget.album.id, m.memberToken),
            self: m.memberToken == widget.album.memberToken,
          ),
      ];

  // A failed refresh must not blank cached rows
  final LatestOnly _feedRefresh = LatestOnly();

  Future<void> _loadMedia({int? markSeenThrough}) async {
    if (mounted && _items.isNotEmpty) {
      setState(() => _feed = AlbumFeedState.refreshing);
    }
    final token = _feedRefresh.begin();
    final span = Trace.start('album.loadMedia',
        traceId: _openTraceId, fields: {'album': Trace.id(widget.album.id)});
    try {
      final items = await Trace.withId(
          _openTraceId, () => _media.listMedia(widget.album.id));
      // A failed newer request must not discard this successful listing
      final current = _feedRefresh.commit(token);
      span.end(fields: {'n': items.length, 'stale': !current});
      if (!current) return;
      // Reconcile only from the complete server listing. The catalog refuses
      // photos already confirmed deleted
      unawaited(_reconcileLocal(items));
      if (!mounted) return;
      final hadRenderableItems = _items.isNotEmpty;
      setState(() {
        _items = items;
        if (!hadRenderableItems && items.isNotEmpty) {
          _renderSource = 'network';
        }
        _feed = items.isEmpty
            ? AlbumFeedState.confirmedEmpty
            : AlbumFeedState.showingCached;
      });
      final landed = {for (final item in items) item.id};
      // Release overlays before the best effort seen write
      _uploads?.recordsLanded(widget.album.id, landed);
      if (markSeenThrough != null) {
        await _markSeen(markSeenThrough);
      }
    } catch (e) {
      span.fail(Trace.reasonOf(e), fields: {'held_items': _items.length});
      if (!mounted || !_feedRefresh.isCurrent(token)) return;
      setState(() => _feed = AlbumFeedState.staleOffline);
    }
  }

  UploadQueueModel? _uploads;
  // Mixed batches can settle again after failed items are retried
  final Map<String, int> _reconciledThrough = {};

  // Uploaders must refresh because they do not receive media_added events
  void _onUploadChange() {
    final queue = _uploads;
    if (queue == null || !mounted) return;
    for (final batch in queue.state.batches) {
      if (batch.albumId != widget.album.id) continue;
      if (!batch.settled || batch.doneCount == 0) continue;
      if ((_reconciledThrough[batch.batchId] ?? 0) >= batch.doneCount) continue;
      _reconciledThrough[batch.batchId] = batch.doneCount;
      unawaited(_loadMedia(
          markSeenThrough:
              batch.mediaGeneration > 0 ? batch.mediaGeneration : null));
    }
  }

  // Keep overlays until the refreshed records are visible
  Future<void> _dismissBatch(String batchId) async {
    _reconciledThrough.remove(batchId);
    _uploads?.requestDismiss(batchId);
    await _loadMedia();
  }

  void _onFirstThumbnailPaint() {
    if (_firstThumbnailReported) return;
    _firstThumbnailReported = true;
    _openClock.stop();
    Trace.event('album.firstThumbnailPaint', fields: {
      'tid': _openTraceId,
      'album': Trace.id(widget.album.id),
      'after_open_ms': _openClock.elapsedMilliseconds,
      'source': _renderSource,
    });
  }

  Future<void> _reconcileLocal(List<MediaRecord> items) async {
    final cache = _catalog;
    if (cache == null) return;
    try {
      await cache.reconcileAlbum(widget.album.id, items);
    } catch (_) {
      // A cache write failure must not hide a valid server response
    }
  }

  // Bounds plaintext picker copies held by one batch
  static const int _maxBatch = 30;

  bool _picking = false;

  Future<void> _pickAndUpload() async {
    final List<XFile> picked;
    // Guard only the system picker so the sheet can open it again
    if (_picking) return;
    _picking = true;
    try {
      picked = await (widget.pickImages ?? _systemPicker)(limit: _maxBatch);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(_note("Couldn't open your photos."));
      }
      return;
    } finally {
      _picking = false;
    }
    if (picked.isEmpty || !mounted) return;
    await _enqueuePicked(picked);
  }

  Future<void> _enqueuePicked(List<XFile> picked) async {
    final model = context.read<UploadQueueModel>();
    final messenger = ScaffoldMessenger.of(context);

    // Some platforms ignore the picker limit, so delete overflow copies
    final taking =
        picked.length > _maxBatch ? picked.sublist(0, _maxBatch) : picked;
    if (picked.length > taking.length) {
      unawaited(model
          .discardUnused([for (final x in picked.skip(_maxBatch)) x.path]));
    }
    final staged = await model.stage([
      for (final x in taking)
        PickedSource(path: x.path, mimeType: x.mimeType ?? 'image/jpeg'),
    ]);
    // Discard staged plaintext if the screen closed
    if (!mounted) {
      unawaited(model.discardUnused([for (final s in staged) s.path]));
      return;
    }
    final batchId = model.startBatch(
      albumId: widget.album.id,
      sources: staged,
    );
    if (picked.length > _maxBatch) {
      messenger.showSnackBar(
          _note('Adding the first $_maxBatch. Add the rest after.'));
    }
    await UploadSheet.show(context,
        batchId: batchId, onPickMore: _pickAndUpload, onDismiss: _dismissBatch);
  }

  @override
  void dispose() {
    _appState?.removeListener(_onAppStateChange);
    _uploads?.removeListener(_onUploadChange);
    _uploads?.stopObserving(widget.album.id);
    _scroll.dispose();
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.album.id;
    // Rebuild for this album's state only, not every app wide notification
    context.select<AppState, Object>((s) => (
          s.isSyncing(id),
          s.keyBlockFor(id),
          s.rotationFor(id)?.phase,
          s.rotationFor(id)?.failure,
          s.albumDisplayName(id),
          s.hiddenMediaVersion,
          [
            for (final m in widget.album.memberPreviews)
              s.memberDisplayName(id, m.memberToken) ?? '',
          ].join('\u0000'),
        ));
    final state = _appState!;
    final syncing = state.isSyncing(widget.album.id);
    // Uploads stay blocked until catch up reaches the refused epoch
    final keyBlock = state.keyBlockFor(widget.album.id);
    final rotation = state.rotationFor(widget.album.id);
    if (_addPending && !syncing && keyBlock == null) {
      _addPending = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_pickAndUpload());
      });
    }

    final memberDisplayNames = _resolvedNames();
    final title = state.albumDisplayName(widget.album.id) ?? 'Album';
    // Shelf previews reserve the roster's space to prevent a layout jump
    final loaded = _members.isNotEmpty;
    final avatars = loaded ? _avatars() : _previewAvatars(state);
    final invited = loaded ? avatars.where((a) => a.pending).length : 0;
    final visible = _visible;
    final shown = _filterToken == null
        ? visible
        : visible.where((r) => r.uploaderToken == _filterToken).toList();
    final stats = AlbumStats.of(visible,
        peopleCount:
            loaded ? avatars.length - invited : widget.album.activeMemberCount);

    final page = Scaffold(
      backgroundColor: Warm.ground,
      body: Stack(
        children: [
          PhotoDragSelect(
            selection: _selection,
            scroll: _scroll,
            order: () => [for (final r in _shown) r.id],
            bottomEdge:
                AlbumFoot.clearance + MediaQuery.paddingOf(context).bottom,
            child: CustomScrollView(
              controller: _scroll,
              slivers: [
                SliverToBoxAdapter(
                  child: SafeArea(
                    bottom: false,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _AlbumTopRow(
                          onBack: () => Navigator.of(context).maybePop(),
                          onSelect: shown.isEmpty ? null : _selection.start,
                          onInfo: _openAlbumInfo,
                          onSettings: _viewerIsAdmin ? _openSettings : null,
                        ),
                        AlbumHeader(
                          albumId: widget.album.id,
                          title: title,
                          summary: stats.summary(),
                          members: avatars,
                          filterToken: _filterToken,
                          filterName: _filterToken == null
                              ? null
                              : memberDisplayNames[_filterToken],
                          filterCount: shown.length,
                          onTapMember: _toggleFilter,
                          onClearFilter: () =>
                              setState(() => _filterToken = null),
                          onAdd: _viewerIsAdmin ? _openAddMember : null,
                          onRename: _viewerIsAdmin ? _rename : null,
                          folded: _collapsed,
                          trust: loaded ? _trustSummary : null,
                          onSecurity: _openSecurity,
                        ),
                      ],
                    ),
                  ),
                ),
                if (keyBlock != null)
                  SliverToBoxAdapter(
                    child: KeyBlockBanner(
                      block: keyBlock,
                      onVerify: () => _verifyBlockingSigner(keyBlock),
                      onRetry: _retryKeySync,
                    ),
                  ),
                if (rotation != null && keyBlock == null)
                  SliverToBoxAdapter(
                    child: RotationBanner(
                        status: rotation, onRetry: _retryRotation),
                  ),
                if (_changedKeyMembers.isNotEmpty)
                  SliverToBoxAdapter(
                    child: KeyChangeBanner(
                      members: _changedKeyMembers,
                      nameOf: _memberName,
                      onTap: _openSafetyNumber,
                    ),
                  ),
                if (syncing && _items.isNotEmpty)
                  const SliverToBoxAdapter(child: AlbumSyncingBanner()),
                if (_feed == AlbumFeedState.staleOffline && _items.isNotEmpty)
                  SliverToBoxAdapter(
                      child: AlbumStaleBanner(onRetry: () => _loadMedia())),
                Selector<UploadQueueModel, List<PendingOverlay>>(
                  selector: (_, queue) => [
                    for (final o in queue.overlaysFor(widget.album.id))
                      (id: o.id, mediaId: o.mediaId.value),
                  ],
                  shouldRebuild: (a, b) => !listEquals(a, b),
                  builder: (context, overlays, _) {
                    if (syncing && _items.isEmpty && overlays.isEmpty) {
                      return const SliverFillRemaining(
                          hasScrollBody: false, child: _SyncingPlaceholder());
                    }
                    return AlbumMediaGrid(
                      items: shown,
                      overlays: _filterToken == null ? overlays : const [],
                      state: _feed,
                      onRetry: _loadMedia,
                      traceId: _openTraceId,
                      onFirstThumbnailPaint: _onFirstThumbnailPaint,
                      onPeek: _openPeek,
                      onOpen: _openViewer,
                      selection: _selection,
                    );
                  },
                ),
                // Keep the final row above the foot bar
                const SliverToBoxAdapter(
                    child: SizedBox(height: AlbumFoot.clearance)),
              ],
            ),
          ),
          ListenableBuilder(
            listenable: _selection,
            builder: (context, _) {
              if (!_selection.active) {
                return AlbumFoot(
                  onAdd: (syncing || keyBlock != null) ? null : _pickAndUpload,
                  pill: const UploadPill(),
                );
              }
              final (picked, mine) = _picked(shown);
              return SelectFoot(
                count: picked.length,
                mine: mine.length,
                onDelete: () => _deleteSelected(mine, picked.length),
              );
            },
          ),
          AlbumTopBar(
            title: title,
            visible: _collapsed,
            onBack: () => Navigator.of(context).maybePop(),
            onSelect: shown.isEmpty ? null : _selection.start,
            onInfo: _openAlbumInfo,
            onSettings: _viewerIsAdmin ? _openSettings : null,
          ),
          ListenableBuilder(
            listenable: _selection,
            builder: (context, _) {
              final (picked, mine) = _picked(shown);
              final all = shown.isNotEmpty && picked.length == shown.length;
              return SelectTopBar(
                visible: _selection.active,
                count: picked.length,
                mine: mine.length,
                allSelected: all,
                onClose: _selection.end,
                onSelectAll: () => _selection
                    .replace(all ? const {} : {for (final r in shown) r.id}),
              );
            },
          ),
        ],
      ),
    );
    // Back leaves select mode before it leaves the album
    return ListenableBuilder(
      listenable: _selection,
      builder: (context, page) => PopScope(
        canPop: !_selection.active,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _selection.end();
        },
        child: page!,
      ),
      child: page,
    );
  }
}

// Lift snackbars above the foot bar
SnackBar _note(String text, {bool brief = false}) => SnackBar(
      content: Text(text),
      duration: brief ? const Duration(seconds: 1) : const Duration(seconds: 4),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, AlbumFoot.clearance),
    );

class _AlbumTopRow extends StatelessWidget {
  final VoidCallback onBack;
  // Null while there is nothing to pick
  final VoidCallback? onSelect;
  final VoidCallback onInfo;
  final VoidCallback? onSettings;

  const _AlbumTopRow(
      {required this.onBack,
      required this.onSelect,
      required this.onInfo,
      this.onSettings});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(
        children: [
          AlbumIconButton(
            icon: Icons.chevron_left_rounded,
            tooltip: AlbumCopy.back,
            onTap: onBack,
          ),
          const Spacer(),
          SelectPill(key: const Key('album-select'), onTap: onSelect),
          const SizedBox(width: 6),
          AlbumCornerButton(onInfo: onInfo, onSettings: onSettings),
        ],
      ),
    );
  }
}

class _SyncingPlaceholder extends StatelessWidget {
  const _SyncingPlaceholder();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(strokeWidth: 2),
          const SizedBox(height: 12),
          Text('Getting the album ready…',
              style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}
