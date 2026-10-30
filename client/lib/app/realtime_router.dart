import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:miuchio/crypto/uuid_bytes.dart';
import 'package:miuchio/data/api/realtime_service.dart';
import 'package:miuchio/data/models/album_summary.dart';
import 'package:miuchio/data/storage/media_cache_manager.dart';
import 'package:miuchio/domain/activity/activity_sync.dart';
import 'package:miuchio/domain/albums/album_cleanup.dart';
import 'package:miuchio/e2ee/epoch_processor.dart';
import 'package:miuchio/e2ee/identity.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/e2ee/member_removal.dart';
import 'package:miuchio/e2ee/rotation_recovery.dart';
import 'package:miuchio/ui/providers/app_state.dart';

// Routes live server events to the services that own them
class RealtimeRouter {
  final IdentityService identity;
  final EpochProcessor epochProcessor;
  final MediaCacheManager mediaCache;
  final AppState appState;
  final ActivitySync activitySync;
  final AlbumCleanupQueue albumCleanup;
  final MemberRemovalCoordinator memberRemoval;
  final RotationRecoveryScheduler rotationRecovery;
  final void Function(String albumId) onAlbumDeleted;

  RealtimeRouter({
    required this.identity,
    required this.epochProcessor,
    required this.mediaCache,
    required this.appState,
    required this.activitySync,
    required this.albumCleanup,
    required this.memberRemoval,
    required this.rotationRecovery,
    required this.onAlbumDeleted,
  });

  void handle(RealtimeEvent ev) {
    switch (ev.type) {
      case 'e2ee.opk_low':
        identity.replenishOpks();
      case 'e2ee.epoch_changed':
        _epochChanged(ev.payload);
      case 'e2ee.media_added':
        _mediaAdded(ev.payload);
      case 'e2ee.album_deleted':
        final albumStr = ev.payload['album_id'] as String?;
        if (albumStr != null) onAlbumDeleted(albumStr);
      case 'e2ee.media_deleted':
        _mediaDeleted(ev.payload);
      // The event names only the album: the fresh listing brings the new
      // sealed title, opened on this phone, and its activity row
      case 'e2ee.album_renamed' || 'e2ee.album_updated':
        if (ev.payload['album_id'] is String) appState.refreshSummarySoon();
      case 'e2ee.member_added' || 'e2ee.member_updated':
        final albumStr = ev.payload['album_id'] as String?;
        if (albumStr == null) return;
        appState.refreshSummarySoon();
        appState.notifyMemberChanged(albumStr);
      case 'e2ee.member_revoked':
        _memberRevoked(ev.payload);
    }
  }

  void _epochChanged(Map<String, dynamic> payload) {
    final albumStr = payload['album_id'] as String?;
    final epoch = payload['epoch'];
    final joined = payload['joined'] == true;
    if (albumStr == null || epoch is! int) return;
    final albumId = uuidToBytes(albumStr);
    if (albumId == null) return;
    epochProcessor
        .handleEvent(albumId: albumId, epoch: epoch, joined: joined)
        .catchError((_) {});
  }

  void _mediaAdded(Map<String, dynamic> payload) {
    final albumStr = payload['album_id'] as String?;
    final mediaStr = payload['media_id'] as String?;
    if (albumStr == null || mediaStr == null) return;
    final recJson = payload['record'];
    if (recJson is Map<String, dynamic>) {
      try {
        final r = MediaRecord.fromJson(recJson);
        unawaited(mediaCache.acceptNewMedia(r));
      } catch (_) {
        unawaited(mediaCache.prefetch(albumStr, mediaStr));
      }
    } else {
      unawaited(mediaCache.prefetch(albumStr, mediaStr));
    }
    final gen = payload['media_generation'];
    if (gen is int) {
      appState.applyMediaAdded(albumStr, gen,
          preview: recJson is Map<String, dynamic>
              ? PreviewMedia.tryFromRecordJson(recJson)
              : null);
    }
    appState.notifyMediaAdded(albumStr, mediaStr);
    activitySync.nudge();
  }

  void _mediaDeleted(Map<String, dynamic> payload) {
    final albumStr = payload['album_id'] as String?;
    final ids = payload['media_ids'];
    if (albumStr == null || ids is! List) return;
    unawaited(() async {
      for (final id in ids.whereType<String>()) {
        appState.confirmMediaDeleted(albumStr, id);
        await mediaCache.markDeleted(albumStr, id);
      }
      appState.notifyMediaRemoved(albumStr);
    }());
  }

  void _memberRevoked(Map<String, dynamic> payload) {
    final albumStr = payload['album_id'] as String?;
    final tokenB64 = payload['member_token'] as String?;
    if (albumStr == null || tokenB64 == null) return;
    final albumId = uuidToBytes(albumStr);
    if (albumId == null) return;
    final token = base64.decode(base64.normalize(tokenB64));
    String? myTokenB64;
    for (final a in appState.albums) {
      if (a.id == albumStr) {
        myTokenB64 = a.memberToken;
        break;
      }
    }
    // Tokens are compared only for routing here, not as secrets
    final isSelf = myTokenB64 != null &&
        listEquals(base64.decode(base64.normalize(myTokenB64)), token);
    if (isSelf) {
      unawaited(albumCleanup.albumGone(albumStr).catchError((_) {}));
    } else {
      memberRemoval.onOtherRemoved(albumId, token);
      appState.refreshSummarySoon();
      unawaited(rotationRecovery.request(albumId));
    }
    appState.notifyMemberChanged(albumStr);
  }

  // Settles SPK state before processing wraps, even for accounts with no albums
  Future<void> catchUpAfterReconnect() async {
    try {
      await identity.settleSpkState();
    } catch (_) {/*diagnostics are logged inside */}

    final ids = <Uint8List>[];
    for (final a in appState.albums) {
      final b = uuidToBytes(a.id);
      if (b != null) ids.add(b);
    }
    if (ids.isEmpty) return;
    try {
      await epochProcessor.catchUpAll(ids);
      appState.refreshAlbumNames();
      await rotationRecovery.checkAll(ids);
    } catch (_) {}
  }
}
