import 'package:miuchio/data/api/media_api.dart';
import 'package:miuchio/data/storage/media_cache_manager.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/ui/providers/app_state.dart';

// Independent of the album screen, so leaving mid request still settles the
// photo. A pending delete only hides the tile, saved files stay until the
// server confirms
Future<bool> deletePhoto({
  required AppState app,
  required MediaApi media,
  required MediaCacheManager? cache,
  required String albumId,
  required MediaRecord record,
}) async {
  app.hideMedia(albumId, record.id);
  try {
    await media.deleteMedia(albumId, record.id);
  } catch (_) {
    app.unhideMedia(albumId, record.id);
    return false;
  }
  app.confirmMediaDeleted(albumId, record.id);
  // A missed realtime event must not bring it back on an offline restart
  try {
    await cache?.markDeleted(albumId, record.id);
  } catch (_) {}
  return true;
}
