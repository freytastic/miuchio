import 'dart:io';
import 'dart:typed_data';

import 'package:miuchio/crypto/uuid_bytes.dart';
import 'package:miuchio/data/storage/avatar_cache.dart';
import 'package:miuchio/data/storage/identity_pin_store.dart';
import 'package:miuchio/data/storage/media_cache_manager.dart';
import 'package:miuchio/data/storage/media_sealed_cache.dart';
import 'package:miuchio/data/storage/name_cache.dart';
import 'package:miuchio/data/storage/own_avatar_store.dart';
import 'package:miuchio/data/upload/upload_outbox.dart';
import 'package:miuchio/e2ee/album_keys.dart';
import 'package:miuchio/e2ee/identity_trust.dart';
import 'package:miuchio/e2ee/rotation_recovery.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/providers/upload_queue_model.dart';
import 'package:miuchio/ui/shelf/seen_store_impl.dart';
import 'package:miuchio/ui/shelf/shelf_covers_impl.dart';

// Removes every local trace of one album, then checks each store because some
// swallow their own deletion errors. Throws if anything is left behind
class AlbumWipe {
  final UploadQueueModel uploadQueue;
  final UploadOutboxStore uploadOutbox;
  final ShelfCoversImpl shelfCovers;
  final MediaCacheManager mediaCache;
  final MediaSealedCache sealedCache;
  final SealedSeenStore seenStore;
  final AlbumKeyStore albumKeys;
  final AppState appState;
  final NameCache nameCache;
  final AvatarCache avatarCache;
  final OwnAvatarStore ownAvatar;
  final IdentityTrust identityTrust;
  final IdentityPinStore identityPins;
  final RotationRecoveryScheduler rotationRecovery;

  AlbumWipe({
    required this.uploadQueue,
    required this.uploadOutbox,
    required this.shelfCovers,
    required this.mediaCache,
    required this.sealedCache,
    required this.seenStore,
    required this.albumKeys,
    required this.appState,
    required this.nameCache,
    required this.avatarCache,
    required this.ownAvatar,
    required this.identityTrust,
    required this.identityPins,
    required this.rotationRecovery,
  });

  Future<void> call(Uint8List albumId) async {
    final albumStr = uuidFromBytes(albumId);
    final picks = await uploadQueue.forgetAlbum(albumStr);
    await shelfCovers.forget(albumStr);
    await mediaCache.clearAlbum(albumStr);
    await seenStore.forget(albumStr);
    await albumKeys.deleteAlbumMKs(albumId);
    // Mark gone first so in flight resolvers cannot repopulate wiped data
    appState.removeAlbum(albumStr);
    await sealedCache.dropAlbum(albumStr);
    await nameCache.clearAlbum(albumStr);
    await avatarCache.clearAlbum(albumStr);
    await ownAvatar.forgetAlbum(albumStr);
    await identityTrust.forgetAlbum(albumId);
    rotationRecovery.forget(albumId);
    final left = <String>[
      for (final path in picks)
        if (await File(path).exists()) 'picked photo',
      if (uploadQueue.holdsAlbum(albumStr)) 'upload queue',
      if (await uploadOutbox.holdsAlbum(albumStr)) 'sealed uploads',
      if ((await sealedCache.listRecordsForAlbum(albumStr)).isNotEmpty)
        'media catalog',
      if ((await sealedCache.coversFor(albumStr)).isNotEmpty) 'covers',
      if ((await sealedCache.loadAlbums()).any((a) => a.id == albumStr))
        'shelf',
      if (await albumKeys.latestEpoch(albumId) >= 0) 'album keys',
      if (nameCache.holdsAlbum(albumStr)) 'names',
      if (await avatarCache.holdsAlbum(albumStr)) 'avatars',
      if (identityPins.holdsAlbum(hexAlbumId(albumId))) 'pins',
      if (seenStore.holdsAlbum(albumStr)) 'seen state',
    ];
    if (left.isNotEmpty) {
      throw StateError('album data left behind: ${left.join(', ')}');
    }
  }
}
