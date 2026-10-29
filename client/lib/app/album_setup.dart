import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import 'package:miuchio/crypto/uuid_bytes.dart';
import 'package:miuchio/data/api/album_api.dart';
import 'package:miuchio/data/models/album_model.dart';
import 'package:miuchio/data/storage/identity_pin_store.dart';
import 'package:miuchio/e2ee/album_keys.dart';
import 'package:miuchio/e2ee/display_name.dart';
import 'package:miuchio/e2ee/epoch_rotator.dart';
import 'package:miuchio/e2ee/identity.dart';
import 'package:miuchio/e2ee/invite.dart';
import 'package:miuchio/e2ee/sealed_name.dart';
import 'package:miuchio/ui/create/invite_dispatcher.dart';
import 'package:miuchio/ui/providers/app_state.dart';

// An album the server created whose keys are not installed yet
class StartedAlbum {
  final AlbumModel album;
  final Uint8List albumIdBytes;
  final Uint8List creatorMemberToken;
  final String creatorUserId;
  // Read at creation so a later rename cannot change the first published name
  final String creatorDisplayName;

  const StartedAlbum({
    required this.album,
    required this.albumIdBytes,
    required this.creatorMemberToken,
    required this.creatorUserId,
    required this.creatorDisplayName,
  });

  String get id => album.id;
}

// Creates an album and installs epoch 0. The create screen and the dev seed
// both run it, so seeded albums go through the same steps as real ones
class AlbumSetup {
  final AppState _appState;
  final IdentityService _identity;
  final EpochRotator _rotator;
  final AlbumKeyStore _albumKeys;
  final DisplayNamePublisher _namePublisher;
  final IdentityPinStore _pinStore;
  final InviteInitiator _inviter;
  final AlbumService _albums;

  AlbumSetup({
    required AppState appState,
    required IdentityService identity,
    required EpochRotator rotator,
    required AlbumKeyStore albumKeys,
    required DisplayNamePublisher namePublisher,
    required IdentityPinStore pinStore,
    required InviteInitiator inviter,
    AlbumService? albums,
  })  : _appState = appState,
        _identity = identity,
        _rotator = rotator,
        _albumKeys = albumKeys,
        _namePublisher = namePublisher,
        _pinStore = pinStore,
        _inviter = inviter,
        _albums = albums ?? AlbumService();

  factory AlbumSetup.of(BuildContext context) => AlbumSetup(
        appState: context.read<AppState>(),
        identity: context.read<IdentityService>(),
        rotator: context.read<EpochRotator>(),
        albumKeys: context.read<AlbumKeyStore>(),
        namePublisher: context.read<DisplayNamePublisher>(),
        pinStore: context.read<IdentityPinStore>(),
        inviter: context.read<InviteInitiator>(),
      );

  // Creates the album on the server. It stays marked syncing until finish
  Future<StartedAlbum> start() async {
    final userId = _appState.userId;
    if (userId == null) throw StateError('Signed out');
    final album = await _albums.createAlbum();
    if (album == null) throw Exception('Album creation failed');
    final tokenB64 = album.memberToken;
    if (tokenB64 == null) {
      throw Exception('Server did not return member_token');
    }
    final albumIdBytes = uuidToBytes(album.id);
    if (albumIdBytes == null) {
      throw Exception('Invalid album id from server');
    }
    // Register self before the signer gate sees the epoch 0 wrap
    _appState.registerSelfToken(album.id, tokenB64);
    // Persist sole signer authority until epoch 0 installs
    await _pinStore.markCreating(album.id);
    // Keep album reads and uploads disabled during setup
    _appState.markSyncing([album.id]);
    return StartedAlbum(
      album: album,
      albumIdBytes: albumIdBytes,
      creatorMemberToken: base64Decode(tokenB64),
      creatorUserId: userId,
      creatorDisplayName: _appState.profileName,
    );
  }

  // Installs keys, seals the title and sends invites. Returns how many
  // invites failed and throws if key setup failed. Always clears syncing so
  // failed setup cannot strand the album
  Future<int> finish(
    StartedAlbum started, {
    required String name,
    List<String> inviteIds = const [],
  }) async {
    final albumId = started.id;
    try {
      await _identity.cryptoReady;
      await _rotator.bootstrap(
        albumIdBytes: started.albumIdBytes,
        creatorMemberToken: started.creatorMemberToken,
        creatorUserId: started.creatorUserId,
      );
      // Close the temporary sole signer window
      await _pinStore.clearCreating(albumId);
      // Seal the title after epoch 0 installs
      final nameCt = await SealedName.sealAlbumName(
          _albumKeys, started.albumIdBytes, 0, name);
      if (await _albums.updateAlbumNameCt(albumId, nameCt)) {
        // Keep a stale shell refresh from restoring the placeholder
        _appState.applyAlbumNameCt(albumId, nameCt, name);
      }
      await _namePublisher.publishToAlbum(
        albumId: albumId,
        memberToken: started.creatorMemberToken,
        name: started.creatorDisplayName,
      );
      // Invites require epoch 0 keys
      return await InviteDispatcher((miuchioId) => _inviter.inviteExistingUser(
              miuchioId: miuchioId, albumId: started.albumIdBytes))
          .sendAll(inviteIds);
    } finally {
      _appState.clearSyncing(albumId);
    }
  }
}
