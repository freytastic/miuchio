import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:miuchio/crypto/uuid_bytes.dart';
import 'package:miuchio/data/storage/activity_store.dart';
import 'package:miuchio/data/storage/media_cache_manager.dart';
import 'package:miuchio/domain/activity/activity_event.dart';
import 'package:miuchio/domain/activity/activity_sync.dart';
import 'package:miuchio/e2ee/identity_trust.dart';
import 'package:miuchio/ui/activity/activity_copy.dart';
import 'package:miuchio/ui/activity/activity_screen.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/shelf/shelf_data.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/encrypted_thumbnail.dart';
import 'package:miuchio/ui/widgets/safety_number_sheet.dart';

class NotificationsScreen extends StatelessWidget {
  // A home tab opens albums itself, a page hands the album back to the shelf
  final void Function(String albumId)? onOpenAlbum;
  final bool asTab;

  const NotificationsScreen({super.key, this.onOpenAlbum, this.asTab = false});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final store = context.read<ActivityFeed>();
    final trust = context.read<IdentityTrust>();
    final sync = context.read<ActivitySync>();
    final names = ActivityNames(
      memberName: (albumId, token) =>
          state.memberDisplayName(albumId, token) ?? 'Someone',
      albumTitle: (id) => state.albumDisplayName(id) ?? 'an album',
    );

    final open = onOpenAlbum ?? (String id) => Navigator.of(context).pop(id);

    return ActivityScreen(
      asTab: asTab,
      store: store,
      refresh: () async {
        await sync.flush();
        await _settleVerified(store, trust);
      },
      thumb: (record) => EncryptedThumbnail(
        record: record,
        cache: context.read<MediaCacheManager>(),
      ),
      cover: (albumId) => _LatestPhoto(albumId: albumId),
      names: names,
      onOpenAlbum: open,
      onCompare: (e) => _compare(context, e, names, store, trust, open),
      onUnreadChanged: state.setUnreadNotifications,
    );
  }

  // Compare the alarm key, never a later roster key
  static Future<void> _compare(
    BuildContext context,
    SafetyNumberChanged e,
    ActivityNames names,
    ActivityFeed store,
    IdentityTrust trust,
    void Function(String albumId) open,
  ) async {
    final ik = e.presentedIk;
    final album = uuidToBytes(e.albumId);
    // Rows recorded before the key was kept can only point at the album
    if (ik == null || album == null) {
      open(e.albumId);
      return;
    }
    final digits = await trust.safetyNumber(albumId: album, peerIkPub: ik);
    if (!context.mounted) return;

    Future<void>? verifying;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Warm.ground,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafetyNumberSheet(
        displayName: names.memberName(e.albumId, e.peerToken),
        digits: digits,
        state: TrustState.changed,
        onVerify: () {
          verifying = () async {
            try {
              await trust.markVerified(
                  albumId: album, memberToken: e.peerToken, peerIkPub: ik);
            } on VerificationNotSaved {
              // The album alarms again after a restart, so no "it matched"
              return;
            }
            await store.resolveVerified(e);
          }();
        },
      ),
    );
    // The sheet closes before its verification writes finish
    await verifying?.catchError((_) {});
  }

  // Settle only when this album's pin agrees with the verified key
  static Future<void> _settleVerified(
      ActivityFeed store, IdentityTrust trust) async {
    for (final r in await store.read(lane: ActivityLane.security)) {
      final e = r.event;
      if (e is! SafetyNumberChanged || e.verified) continue;
      final Uint8List? ik = e.presentedIk;
      final album = uuidToBytes(e.albumId);
      if (ik == null || album == null) continue;
      if (await trust.isResolved(
          albumId: album, memberToken: e.peerToken, peerIkPub: ik)) {
        await store.resolveVerified(e);
      }
    }
  }
}

// The album's newest photo, from the same decrypted covers the shelf shows
class _LatestPhoto extends StatefulWidget {
  final String albumId;

  const _LatestPhoto({required this.albumId});

  @override
  State<_LatestPhoto> createState() => _LatestPhotoState();
}

class _LatestPhotoState extends State<_LatestPhoto> {
  ShelfCovers? get _covers {
    try {
      return context.read<ShelfCovers>();
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    final album = context
        .read<AppState>()
        .albums
        .where((a) => a.id == widget.albumId)
        .firstOrNull;
    if (album != null) _covers?.ensureCover(album.id, album.previewMedia);
  }

  @override
  Widget build(BuildContext context) {
    final covers = _covers;
    if (covers != null) context.watch<ShelfCovers>();
    final bytes = covers?.bytes(widget.albumId, 0);
    if (bytes == null) return const SizedBox.shrink();
    return Image.memory(bytes,
        fit: BoxFit.cover, gaplessPlayback: true, width: double.infinity);
  }
}
