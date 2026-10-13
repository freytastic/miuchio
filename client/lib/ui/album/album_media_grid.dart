import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:miuchio/data/storage/media_cache_manager.dart';
import 'package:miuchio/ui/album/photo_hold.dart';
import 'package:miuchio/ui/providers/upload_queue_model.dart';
import 'package:miuchio/ui/widgets/upload_tile.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/diagnostics/perf_probe.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/decrypted_image_preview.dart';
import 'package:miuchio/ui/widgets/encrypted_thumbnail.dart';

// Distinguishes a confirmed empty album from an unavailable one
enum AlbumFeedState {
  loadingNoCache,
  showingCached,
  refreshing,
  staleOffline,
  confirmedEmpty,
}

typedef PendingOverlay = ({String id, String mediaId});

class AlbumMediaGrid extends StatelessWidget {
  final List<MediaRecord> items;
  final List<PendingOverlay> overlays;
  final AlbumFeedState state;
  final Future<void> Function() onRetry;
  final String traceId;
  final VoidCallback onFirstThumbnailPaint;
  final void Function(MediaRecord record, DecryptedImagePreview preview,
      ImageProvider onScreen) onPeek;
  final void Function(MediaRecord record) onOpen;

  const AlbumMediaGrid({
    super.key,
    required this.items,
    required this.overlays,
    required this.state,
    required this.onRetry,
    required this.traceId,
    required this.onFirstThumbnailPaint,
    required this.onPeek,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty && overlays.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: switch (state) {
          AlbumFeedState.loadingNoCache ||
          AlbumFeedState.refreshing =>
            const Center(child: CircularProgressIndicator()),
          AlbumFeedState.staleOffline => _MediaUnavailable(onRetry: onRetry),
          AlbumFeedState.confirmedEmpty ||
          AlbumFeedState.showingCached =>
            const _MediaEmpty(),
        },
      );
    }
    // Confirmed records replace matching optimistic tiles
    final landed = {for (final r in items) r.id};
    final pending = [
      for (final o in overlays)
        if (!landed.contains(o.mediaId)) o
    ];

    // Preserve tile elements when pending and confirmed rows shift
    final slotOf = <String, int>{};
    for (var i = 0; i < pending.length; i++) {
      slotOf['p:${pending[i].id}'] = i;
    }
    for (var i = 0; i < items.length; i++) {
      slotOf['m:${items[i].id}'] = pending.length + i;
    }

    return SliverGrid(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, i) {
          if (i < pending.length) {
            final item = pending[i];
            return UploadTile(
              key: ValueKey('p:${item.id}'),
              itemId: item.id,
              onRetry: () => context.read<UploadQueueModel>().retry(item.id),
            );
          }
          final cache = context.read<MediaCacheManager>();
          final record = items[i - pending.length];
          return _MediaTile(
            key: ValueKey('m:${record.id}'),
            record: record,
            cache: cache,
            traceId: traceId,
            onFirstThumbnailPaint: onFirstThumbnailPaint,
            onPeek: onPeek,
            onOpen: onOpen,
          );
        },
        childCount: pending.length + items.length,
        findChildIndexCallback: (key) =>
            slotOf[(key as ValueKey<String>).value],
      ),
    );
  }
}

class _MediaTile extends StatefulWidget {
  final MediaRecord record;
  final MediaCacheManager cache;
  final String traceId;
  final VoidCallback onFirstThumbnailPaint;
  final void Function(MediaRecord record, DecryptedImagePreview preview,
      ImageProvider onScreen) onPeek;
  final void Function(MediaRecord record) onOpen;

  const _MediaTile({
    super.key,
    required this.record,
    required this.cache,
    required this.traceId,
    required this.onFirstThumbnailPaint,
    required this.onPeek,
    required this.onOpen,
  });

  @override
  State<_MediaTile> createState() => _MediaTileState();
}

class _MediaTileState extends State<_MediaTile> {
  DecryptedImagePreview? _preview;

  @override
  void didUpdateWidget(covariant _MediaTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.record.id != widget.record.id) _preview = null;
  }

  void _rememberPreview(DecryptedImagePreview preview) {
    _preview = preview;
  }

  void _openPeek(LongPressStartDetails _) {
    final preview = _preview;
    final size = context.size;
    if (preview == null || size == null) return;
    widget.onPeek(
      widget.record,
      preview,
      EncryptedThumbnail.imageFor(
          preview.bytes, size.width, MediaQuery.devicePixelRatioOf(context)),
    );
  }

  @override
  Widget build(BuildContext context) {
    PerfProbe.count('tile');
    return PhotoHold(
      onStart: _openPeek,
      child: GestureDetector(
        onTap: () => widget.onOpen(widget.record),
        child: ColoredBox(
          color: Warm.wellEmpty,
          child: EncryptedThumbnail(
            record: widget.record,
            cache: widget.cache,
            traceId: widget.traceId,
            onFirstFrame: widget.onFirstThumbnailPaint,
            onReady: _rememberPreview,
          ),
        ),
      ),
    );
  }
}

class _MediaUnavailable extends StatelessWidget {
  final Future<void> Function() onRetry;
  const _MediaUnavailable({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 32, color: Warm.inkSoft),
          const SizedBox(height: 12),
          Text("Couldn't load this album",
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 8),
          TextButton(
              onPressed: () => onRetry(), child: const Text('Try again')),
        ],
      ),
    );
  }
}

class _MediaEmpty extends StatelessWidget {
  const _MediaEmpty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.photo_library_outlined,
              size: 48, color: Warm.inkFaint),
          const SizedBox(height: 12),
          const Text('No photos yet',
              style: TextStyle(
                  color: Warm.inkSoft,
                  fontSize: 16,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          const Text('Tap + to add photos',
              style: TextStyle(color: Warm.inkFaint, fontSize: 13)),
        ],
      ),
    );
  }
}
