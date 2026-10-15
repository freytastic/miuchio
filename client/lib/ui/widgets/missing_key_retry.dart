import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:miuchio/data/storage/media_cache_manager.dart';

// A missing key usually means the sync has not landed yet, so the tile keeps
// its spinner and retries when keys for its album are installed
mixin MissingKeyRetry<T extends StatefulWidget> on State<T> {
  StreamSubscription<String>? _keyWait;
  StreamSubscription<String>? _syncFailed;

  // genAtStart catches an install that landed during the failed attempt,
  // and after onGaveUp shows the failure a later install still heals it
  void waitForKey(MediaCacheManager cache, String albumId, int genAtStart,
      VoidCallback retry, VoidCallback onGaveUp) {
    stopWaitingForKey();
    if (cache.keyGeneration(albumId) != genAtStart) {
      retry();
      return;
    }
    final id = albumId.toLowerCase();
    _keyWait = cache.keysInstalled.where((a) => a == id).listen((_) {
      stopWaitingForKey();
      if (mounted) retry();
    });
    _syncFailed = cache.keySyncFailed.where((a) => a == id).listen((_) {
      _syncFailed?.cancel();
      _syncFailed = null;
      if (mounted) onGaveUp();
    });
  }

  void stopWaitingForKey() {
    _keyWait?.cancel();
    _keyWait = null;
    _syncFailed?.cancel();
    _syncFailed = null;
  }

  @override
  void dispose() {
    stopWaitingForKey();
    super.dispose();
  }
}
