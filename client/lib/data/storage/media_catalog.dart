import 'package:miuchio/data/models/album_model.dart';
import 'package:miuchio/e2ee/media_record.dart';

// Cached album metadata used for local first rendering
abstract class MediaCatalog {
  // In album order, a page at a time when limit is given
  Future<List<MediaRecord>> listRecordsForAlbum(String albumId,
      {int? limit, int offset = 0});

  // Missing rows are removed, so records must be a complete server listing
  Future<void> reconcileAlbum(String albumId, List<MediaRecord> records);
}

// Durable shelf metadata for local first rendering
abstract class AlbumCatalog {
  Future<List<AlbumModel>> loadAlbums();

  // Albums must be a complete shelf listing
  Future<void> saveAlbums(List<AlbumModel> albums);

  // Revocation and deletion must remove the durable album entry
  Future<void> dropAlbum(String albumId);
}
