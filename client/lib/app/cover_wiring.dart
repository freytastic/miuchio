import 'package:miuchio/crypto/uuid_bytes.dart';
import 'package:miuchio/data/api/cover_api.dart';
import 'package:miuchio/data/storage/cover_cache.dart';
import 'package:miuchio/domain/albums/cover_setter.dart';
import 'package:miuchio/e2ee/album_keys.dart';
import 'package:miuchio/e2ee/sealed_cover.dart';

// Downloads an album's uploaded cover and opens it under the album keys
FetchCover coverFetcher(AlbumKeyStore albumKeys, CoverApi api) =>
    (albumId, ref) async {
      final b = uuidToBytes(albumId);
      if (b == null || !ref.isUpload) return null;
      return CoverCrypto.open(
        ks: albumKeys,
        albumId: b,
        coverId: ref.coverId,
        keyCt: ref.keyCt!,
        blobSha256: ref.blobSha256!,
        blob: await api.download(albumId, ref),
      );
    };

CoverSetter coverSetter(
        AlbumKeyStore albumKeys, CoverApi api, CoverCache cache) =>
    CoverSetter(
      seal: (albumId, jpeg) async {
        final b = uuidToBytes(albumId);
        if (b == null || await albumKeys.latestEpoch(b) < 0) return null;
        return CoverCrypto.seal(ks: albumKeys, albumId: b, jpeg: jpeg);
      },
      upload: api.upload,
      choose: api.choosePhoto,
      remember: cache.remember,
    );
