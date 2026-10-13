import 'dart:convert';

import 'package:miuchio/crypto/uuid_bytes.dart';
import 'package:miuchio/data/api/avatar_api.dart';
import 'package:miuchio/data/storage/avatar_cache.dart';
import 'package:miuchio/domain/avatar/avatar_publisher.dart';
import 'package:miuchio/e2ee/album_keys.dart';
import 'package:miuchio/e2ee/sealed_avatar.dart';

// Downloads one member's avatar and opens it under the album keys
FetchAvatar avatarFetcher(AlbumKeyStore albumKeys, AvatarApi api) =>
    (albumId, token, ref) async {
      final b = uuidToBytes(albumId);
      if (b == null) return null;
      return AvatarCrypto.open(
        ks: albumKeys,
        albumId: b,
        memberToken: base64.decode(base64.normalize(token)),
        avatarId: ref.avatarId,
        keyCt: ref.keyCt,
        blobSha256: ref.blobSha256,
        blob: await api.download(albumId, ref),
      );
    };

// Null until the album has a key installed on this phone
SealAvatar avatarSealer(AlbumKeyStore albumKeys) =>
    (albumId, token, jpeg) async {
      final b = uuidToBytes(albumId);
      if (b == null || await albumKeys.latestEpoch(b) < 0) return null;
      return AvatarCrypto.seal(
        ks: albumKeys,
        albumId: b,
        memberToken: base64.decode(base64.normalize(token)),
        jpeg: jpeg,
      );
    };
