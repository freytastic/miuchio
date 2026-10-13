import 'package:miuchio/data/api/auth_api.dart';
import 'package:miuchio/data/storage/media_cache_manager.dart';
import 'package:miuchio/data/storage/name_cache.dart';

// Drops tokens and wipes the media and name caches. cache_root_key, identity
// and album MKs are device bound and survive. Deleting cache_root_key here
// would strand blobs a re login reseals under the key still held in RAM
Future<void> performLogout({
  required AuthService auth,
  required MediaCacheManager mediaCache,
  required NameCache nameCache,
  Future<void> Function()? disconnectRealtime,
}) async {
  // Socket first so no live event lands mid teardown, a failed disconnect
  // must not block the wipe
  if (disconnectRealtime != null) {
    try {
      await disconnectRealtime();
    } catch (_) {}
  }
  await auth.logout();
  await mediaCache.clearAll();
  await nameCache.clear();
}
