import 'dart:convert';

import 'package:miuchio/crypto/uuid_bytes.dart';
import 'package:miuchio/data/storage/name_cache.dart';
import 'package:miuchio/e2ee/album_keys.dart';
import 'package:miuchio/e2ee/display_name.dart';
import 'package:miuchio/e2ee/sealed_name.dart';

// Names are cached only while the album is still listed, since an album wipe
// may finish while a name is decrypting
Future<String> Function(String albumId, String? nameCt) albumNameResolver({
  required NameCache cache,
  required AlbumKeyStore albumKeys,
  required bool Function(String albumId) isListed,
}) =>
    (albumId, nameCt) async {
      if (nameCt == null || nameCt.isEmpty) return 'Untitled album';
      final key = NameCache.albumKey(albumId);
      final cached = cache.get(key, nameCt);
      if (cached != null) return cached;
      final b = uuidToBytes(albumId);
      if (b == null) return 'Untitled album';
      final opened = await SealedName.openAlbumName(albumKeys, b, nameCt);
      if (opened != null) {
        if (isListed(albumId)) cache.put(key, opened, nameCt);
        return opened;
      }
      return resolveAlbumName(albumKeys, b, nameCt);
    };

Future<String?> Function(String albumId, String memberToken, String? nameCt)
    memberNameResolver({
  required NameCache cache,
  required AlbumKeyStore albumKeys,
  required bool Function(String albumId) isListed,
}) =>
        (albumId, memberToken, nameCt) async {
          if (nameCt == null || nameCt.isEmpty) return null;
          final key = NameCache.memberKey(albumId, memberToken);
          final cached = cache.get(key, nameCt);
          if (cached != null) return cached;
          final b = uuidToBytes(albumId);
          if (b == null) return null;
          final token = base64.decode(base64.normalize(memberToken));
          final opened =
              await SealedName.openMemberName(albumKeys, b, token, nameCt);
          if (opened != null && isListed(albumId)) {
            cache.put(key, opened, nameCt);
          }
          return opened;
        };
