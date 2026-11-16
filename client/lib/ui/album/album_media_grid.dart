import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:miuchio/data/storage/media_cache_manager.dart';
import 'package:miuchio/ui/album/photo_hold.dart';
import 'package:miuchio/ui/album/photo_sheets.dart';
import 'package:miuchio/ui/album/photo_select.dart';
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
  final PhotoSelection selection;

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
    required this.selection,
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

    // Days are the finest time the album shows, so they are the sections, and
    // photos still sending belong to today
    final days = <_Day>[];
    final seen = <String, int>{};
    void open(String label) {
      // Out of order records can bring a day back, which needs its own key
      final run = seen[label] = (seen[label] ?? 0) + 1;
      days.add(_Day(label, run));
    }

    if (pending.isNotEmpty) open(formatPhotoDay(DateTime.now()));
    for (final r in items) {
      final label = formatPhotoDay(r.createdAt);
      if (days.isEmpty || days.last.label != label) open(label);
      days.last.records.add(r);
    }
    days.first.pending.addAll(pending);

    // One lazy grid for every day, since a grid per day would each build a
    // first tile offscreen and start its thumbnail
    final tiles = <Widget Function(BuildContext)>[];
    final slotOf = <String, int>{};
    void slot(String key, Widget Function(BuildContext) build) {
      slotOf[key] = tiles.length;
      tiles.add(build);
    }

    for (final day in days) {
      final head = 'h:${day.label}:${day.run}';
      slot(head, (_) => _DayHead(key: ValueKey(head), day: day));
      for (final item in day.pending) {
        slot(
            'p:${item.id}',
            (context) => UploadTile(
                  key: ValueKey('p:${item.id}'),
                  itemId: item.id,
                  onRetry: () =>
                      context.read<UploadQueueModel>().retry(item.id),
                ));
      }
      for (final record in day.records) {
        slot(
            'm:${record.id}',
            (context) => _MediaTile(
                  key: ValueKey('m:${record.id}'),
                  record: record,
                  cache: context.read<MediaCacheManager>(),
                  traceId: traceId,
                  onFirstThumbnailPaint: onFirstThumbnailPaint,
                  onPeek: onPeek,
                  onOpen: onOpen,
                  selection: selection,
                ));
      }
    }

    return SliverGrid(
      gridDelegate: _DayGridDelegate(
        counts: [for (final d in days) d.count],
        headExtent: _DayHead.extent(context),
      ),
      delegate: SliverChildBuilderDelegate(
        (context, i) => tiles[i](context),
        childCount: tiles.length,
        // Preserve tile elements when pending and confirmed rows shift
        findChildIndexCallback: (key) =>
            slotOf[(key as ValueKey<String>).value],
      ),
    );
  }
}

// Day headers span the width and each day's photos fill three columns under
// its header, so the whole album is one grid that builds only what is near
// the screen
class _DayGridDelegate extends SliverGridDelegate {
  final List<int> counts;
  final double headExtent;

  _DayGridDelegate({required this.counts, required this.headExtent});

  static const _columns = 3;
  static const _gap = 2.0;

  // Scrolling lays the grid out every frame, so the geometry is built once
  // per width, and a new delegate comes only with new days or text size
  _DayGridLayout? _layout;
  double? _layoutWidth;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final width = constraints.crossAxisExtent;
    final cached = _layout;
    if (cached != null && _layoutWidth == width) return cached;
    final tile = (width - _gap * (_columns - 1)) / _columns;
    final layout = _DayGridLayout();
    var y = 0.0;
    for (final n in counts) {
      layout.add(y, 0, width, headExtent);
      y += headExtent;
      for (var i = 0; i < n; i++) {
        layout.add(y + (i ~/ _columns) * (tile + _gap),
            (i % _columns) * (tile + _gap), tile, tile);
      }
      final rows = (n + _columns - 1) ~/ _columns;
      if (rows > 0) y += rows * tile + (rows - 1) * _gap;
    }
    _layoutWidth = width;
    return _layout = layout;
  }

  @override
  bool shouldRelayout(_DayGridDelegate old) {
    final same = old.headExtent == headExtent && listEquals(old.counts, counts);
    // A rebuild with the same days keeps the geometry already worked out
    if (same && _layout == null) {
      _layout = old._layout;
      _layoutWidth = old._layoutWidth;
    }
    return !same;
  }
}

class _DayGridLayout extends SliverGridLayout {
  final List<double> _top = [];
  final List<double> _left = [];
  final List<double> _width = [];
  final List<double> _height = [];

  void add(double top, double left, double width, double height) {
    _top.add(top);
    _left.add(left);
    _width.add(width);
    _height.add(height);
  }

  // Tops and bottoms only grow with the index, so both can be searched
  int _first(bool Function(int i) after) {
    var lo = 0, hi = _top.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (after(mid)) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo;
  }

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) => math.min(
      _first((i) => _top[i] + _height[i] > scrollOffset), _top.length - 1);

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) =>
      math.max(0, _first((i) => _top[i] > scrollOffset) - 1);

  @override
  SliverGridGeometry getGeometryForChildIndex(int index) => SliverGridGeometry(
        scrollOffset: _top[index],
        crossAxisOffset: _left[index],
        mainAxisExtent: _height[index],
        crossAxisExtent: _width[index],
      );

  @override
  double computeMaxScrollOffset(int childCount) {
    if (childCount == 0) return 0;
    final last = math.min(childCount, _top.length) - 1;
    return _top[last] + _height[last];
  }
}

class _Day {
  final String label;
  final int run;
  final List<PendingOverlay> pending = [];
  final List<MediaRecord> records = [];

  _Day(this.label, this.run);

  int get count => pending.length + records.length;
}

class _DayHead extends StatelessWidget {
  final _Day day;

  const _DayHead({super.key, required this.day});

  static const double _top = 14;
  static const double _bottom = 8;

  // A grid needs the height up front, so it follows the text size setting
  static double extent(BuildContext context) =>
      _top +
      _bottom +
      MediaQuery.textScalerOf(context).scale(Warm.albumDay.fontSize!) * 1.3;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, _top, 24, _bottom),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(child: Text(day.label, style: Warm.albumDay)),
          Text('${day.count}', style: Warm.albumDayCount),
        ],
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
  final PhotoSelection selection;

  const _MediaTile({
    super.key,
    required this.record,
    required this.cache,
    required this.traceId,
    required this.onFirstThumbnailPaint,
    required this.onPeek,
    required this.onOpen,
    required this.selection,
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

  void _tap() {
    final selection = widget.selection;
    if (selection.active) {
      selection.toggle(widget.record.id);
    } else {
      widget.onOpen(widget.record);
    }
  }

  @override
  Widget build(BuildContext context) {
    PerfProbe.count('tile');
    final selection = widget.selection;
    final id = widget.record.id;
    return MetaData(
      metaData: PhotoMark(id),
      behavior: HitTestBehavior.translucent,
      child: PhotoHold(
        onStart: _openPeek,
        child: GestureDetector(
          onTap: _tap,
          // Only the mark and scale follow the selection, never the thumbnail
          child: ListenableBuilder(
            listenable: selection,
            builder: (context, thumb) {
              final on = selection.active && selection.contains(id);
              return Stack(
                fit: StackFit.expand,
                children: [
                  AnimatedScale(
                    scale: on ? 0.88 : 1,
                    duration: Warm.quick,
                    curve: Warm.easeOut,
                    child: thumb,
                  ),
                  if (selection.active)
                    Positioned(top: 6, right: 6, child: SelectMark(on: on)),
                ],
              );
            },
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
          const Text('Tap + to add up to 30 photos at a time',
              style: TextStyle(color: Warm.inkFaint, fontSize: 13)),
        ],
      ),
    );
  }
}
