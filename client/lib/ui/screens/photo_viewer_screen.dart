import 'dart:async';

import 'package:flutter/material.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/data/storage/media_cache_manager.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/ui/album/album_copy.dart';
import 'package:miuchio/ui/album/peek_dock.dart';
import 'package:miuchio/ui/album/photo_sheets.dart';
import 'package:miuchio/ui/widgets/encrypted_image.dart';
import 'package:miuchio/ui/widgets/encrypted_thumbnail.dart';

class PhotoViewerScreen extends StatefulWidget {
  final List<MediaRecord> records;
  final int initialIndex;
  final MediaCacheManager cache;
  final String? Function(String token) nameOf;
  final Widget Function(String token, double size) faceOf;
  final bool Function(MediaRecord record) isOwner;
  // The page goes at once, false brings it back
  final Future<bool> Function(MediaRecord record) onDelete;
  final Widget Function(MediaRecord record, int cacheWidth)? imageBuilder;

  const PhotoViewerScreen({
    super.key,
    required this.records,
    required this.initialIndex,
    required this.cache,
    required this.nameOf,
    required this.faceOf,
    required this.isOwner,
    required this.onDelete,
    this.imageBuilder,
  });

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  static const _swipe = 70.0;
  static const _flick = 520.0;

  late final List<MediaRecord> _records = [...widget.records];
  late final PageController _pages =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  // Shown on open, a tap leaves the photo alone on the screen
  bool _chrome = true;
  bool _zoomed = false;
  // A second finger means a pinch, so paging and swipes stand down until the
  // fingers lift and the zoom gets the gesture from the first touch
  int _fingers = 0;
  String? _lastDeleted;
  double _dragY = 0;

  MediaRecord get _current => _records[_index];

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  String? _nameOf(MediaRecord r) =>
      widget.isOwner(r) ? AlbumCopy.you : widget.nameOf(r.uploaderToken);

  Future<void> _details() => showPhotoDetails(
        context,
        record: _current,
        face: widget.faceOf(_current.uploaderToken, 40),
        name: _nameOf(_current),
        mine: widget.isOwner(_current),
        position: '${_index + 1} / ${_records.length}',
      );

  bool get _held => _zoomed || _fingers > 1;

  void _touch(int by) {
    final was = _fingers > 1;
    _fingers = (_fingers + by).clamp(0, 10);
    if (was != _fingers > 1) setState(() {});
  }

  void _onVerticalEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    final dy = _dragY;
    _dragY = 0;
    if (dy < -_swipe || v < -_flick) {
      _details();
    } else if (dy > _swipe * 1.3 || v > _flick) {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _delete() async {
    // Chosen before the sheet opens, a restore underneath can move _current
    final record = _current;
    if (!await confirmPhotoDelete(context) || !mounted) return;
    _lastDeleted = record.id;
    final gone = widget.onDelete(record);
    setState(() {
      _records.removeWhere((r) => r.id == record.id);
      if (_index > _records.length - 1) _index = _records.length - 1;
    });
    if (_records.isEmpty) {
      Navigator.of(context).maybePop();
      return;
    }
    if (_pages.hasClients) _pages.jumpToPage(_index);
    // A closing viewer leaves the restore to the grid
    if (await gone || !mounted || _records.isEmpty) return;
    _restore(record);
  }

  // Back in album order, which survives other deletes in between. The latest
  // delete shows again if the user is still on the page that replaced it
  void _restore(MediaRecord record) {
    final order = {
      for (var i = 0; i < widget.records.length; i++) widget.records[i].id: i
    };
    final rank = order[record.id] ?? widget.records.length;
    var at = _records.indexWhere((r) => (order[r.id] ?? 0) > rank);
    if (at < 0) at = _records.length;
    final show = at == _index && _lastDeleted == record.id;
    setState(() {
      _records.insert(at, record);
      if (at < _index || (at == _index && !show)) _index++;
    });
    if (_pages.hasClients) _pages.jumpToPage(_index);
  }

  @override
  Widget build(BuildContext context) {
    // Bound decoded image memory by the display resolution
    final media = MediaQuery.of(context);
    final cap = (media.size.longestSide * media.devicePixelRatio).round();
    if (_records.isEmpty) {
      return const Scaffold(backgroundColor: Colors.black);
    }
    final record = _current;
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        // The default theme uses dark status bar icons
        systemOverlayStyle: Warm.overlayOnPeek,
        automaticallyImplyLeading: false,
        toolbarHeight: 0,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Listener(
            onPointerDown: (_) => _touch(1),
            onPointerUp: (_) => _touch(-1),
            onPointerCancel: (_) => _touch(-1),
            child: GestureDetector(
              onVerticalDragUpdate: _held ? null : (d) => _dragY += d.delta.dy,
              onVerticalDragEnd: _held ? null : _onVerticalEnd,
              child: PageView.builder(
                key: const Key('photo-viewer-pages'),
                controller: _pages,
                // Let zoomed and pinched photos pan without changing pages
                physics: _held
                    ? const NeverScrollableScrollPhysics()
                    : const PageScrollPhysics(),
                itemCount: _records.length,
                onPageChanged: (i) => setState(() {
                  _index = i;
                  _zoomed = false;
                }),
                itemBuilder: (context, i) => _ZoomPage(
                  key: ValueKey(_records[i].id),
                  onTap: () => setState(() => _chrome = !_chrome),
                  onZoom: (zoomed) {
                    if (zoomed == _zoomed) return;
                    setState(() {
                      _zoomed = zoomed;
                      if (zoomed) _chrome = false;
                    });
                  },
                  child: widget.imageBuilder?.call(_records[i], cap) ??
                      _FullPhoto(
                        record: _records[i],
                        cache: widget.cache,
                        cacheWidth: cap,
                      ),
                ),
              ),
            ),
          ),
          _Chrome(
            visible: _chrome,
            top: _TopBar(
              face: widget.faceOf(record.uploaderToken, 32),
              name: _nameOf(record) ?? AlbumCopy.unknownMember,
              day: formatPhotoDay(record.createdAt),
              position: '${_index + 1} / ${_records.length}',
            ),
            bottom: _BottomBar(
              strip: _records.length < 2
                  ? null
                  : _Strip(
                      records: _records,
                      index: _index,
                      cache: widget.cache,
                      onPick: (i) => _pages.jumpToPage(i),
                    ),
              owner: widget.isOwner(record),
              onDetails: _details,
              onDelete: _delete,
            ),
          ),
        ],
      ),
    );
  }
}

class _FullPhoto extends StatefulWidget {
  final MediaRecord record;
  final MediaCacheManager cache;
  final int cacheWidth;

  const _FullPhoto({
    required this.record,
    required this.cache,
    required this.cacheWidth,
  });

  @override
  State<_FullPhoto> createState() => _FullPhotoState();
}

class _FullPhotoState extends State<_FullPhoto> {
  bool _ready = false;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.record.hasThumb)
          EncryptedThumbnail(
            record: widget.record,
            cache: widget.cache,
            fit: BoxFit.contain,
          ),
        AnimatedOpacity(
          opacity: _ready || !widget.record.hasThumb ? 1 : 0,
          duration: const Duration(milliseconds: 140),
          curve: Warm.easeOut,
          child: EncryptedImage(
            record: widget.record,
            cache: widget.cache,
            fit: BoxFit.contain,
            cacheWidth: widget.cacheWidth,
            onFirstFrame: () {
              if (mounted) setState(() => _ready = true);
            },
          ),
        ),
      ],
    );
  }
}

class _ZoomPage extends StatefulWidget {
  final VoidCallback onTap;
  final ValueChanged<bool> onZoom;
  final Widget child;

  const _ZoomPage({
    super.key,
    required this.onTap,
    required this.onZoom,
    required this.child,
  });

  @override
  State<_ZoomPage> createState() => _ZoomPageState();
}

class _ZoomPageState extends State<_ZoomPage>
    with SingleTickerProviderStateMixin {
  static const _doubleTapScale = 2.5;

  final TransformationController _zoom = TransformationController();
  late final AnimationController _anim;
  late final CurvedAnimation _curve;
  Matrix4Tween? _tween;
  Offset _tapAt = Offset.zero;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    )..addListener(() {
        final tween = _tween;
        if (tween != null) _zoom.value = tween.evaluate(_curve);
      });
    _curve = CurvedAnimation(parent: _anim, curve: Warm.easeOut);
  }

  bool get _isZoomed => _zoom.value.getMaxScaleOnAxis() > 1.01;

  @override
  void dispose() {
    _curve.dispose();
    _anim.dispose();
    _zoom.dispose();
    super.dispose();
  }

  void _animateTo(Matrix4 target) {
    _tween = Matrix4Tween(begin: _zoom.value, end: target);
    _anim.forward(from: 0).whenComplete(() => widget.onZoom(_isZoomed));
  }

  void _onDoubleTap() {
    if (_isZoomed) {
      _animateTo(Matrix4.identity());
      return;
    }
    // Anchor the zoom at the tapped point
    const s = _doubleTapScale;
    _animateTo(Matrix4.identity()
      ..translateByDouble(-_tapAt.dx * (s - 1), -_tapAt.dy * (s - 1), 0, 1)
      ..scaleByDouble(s, s, 1, 1));
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTapDown: (d) => _tapAt = d.localPosition,
      onDoubleTap: _onDoubleTap,
      child: InteractiveViewer(
        transformationController: _zoom,
        minScale: 1,
        maxScale: 4,
        onInteractionEnd: (_) => widget.onZoom(_isZoomed),
        child: SizedBox.expand(child: widget.child),
      ),
    );
  }
}

class _Chrome extends StatelessWidget {
  final bool visible;
  final Widget top;
  final Widget bottom;

  const _Chrome({
    required this.visible,
    required this.top,
    required this.bottom,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        key: const Key('photo-viewer-chrome'),
        opacity: visible ? 1 : 0,
        duration: Warm.quick,
        curve: Warm.easeOut,
        child: Column(
          children: [
            DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x99000000), Color(0x00000000)],
                ),
              ),
              child: SafeArea(bottom: false, child: top),
            ),
            const Spacer(),
            DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0x99000000), Color(0x00000000)],
                ),
              ),
              child: SafeArea(top: false, child: bottom),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final Widget face;
  final String name;
  final String day;
  final String position;

  const _TopBar({
    required this.face,
    required this.name,
    required this.day,
    required this.position,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 18, 22),
      child: Row(
        children: [
          IconButton(
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          ),
          face,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                Text(
                  day,
                  style:
                      const TextStyle(fontSize: 12.5, color: Color(0xB3FFFFFF)),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: Warm.glassFill,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Warm.glassHairline),
            ),
            child: Text(
              position,
              key: const Key('photo-viewer-position'),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xD9FFFFFF),
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  final Widget? strip;
  final bool owner;
  final VoidCallback onDetails;
  final VoidCallback onDelete;

  const _BottomBar({
    required this.strip,
    required this.owner,
    required this.onDetails,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 28, 0, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (strip != null) ...[strip!, const SizedBox(height: 18)],
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              PeekRoundButton(
                key: const Key('photo-viewer-details'),
                label: AlbumCopy.details,
                icon: Icons.info_outline_rounded,
                onTap: onDetails,
              ),
              if (owner) ...[
                const SizedBox(width: 18),
                PeekRoundButton(
                  key: const Key('photo-peek-delete'),
                  label: AlbumCopy.delete,
                  icon: Icons.delete_outline_rounded,
                  quiet: true,
                  onTap: onDelete,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// Every photo of the album as a small frame, the current one lifted and
// centred, from the same on-device thumbnails as the grid
class _Strip extends StatefulWidget {
  final List<MediaRecord> records;
  final int index;
  final MediaCacheManager cache;
  final ValueChanged<int> onPick;

  const _Strip({
    required this.records,
    required this.index,
    required this.cache,
    required this.onPick,
  });

  static const double _w = 34;
  static const double _h = 46;
  static const double _step = _w + 3;

  @override
  State<_Strip> createState() => _StripState();
}

class _StripState extends State<_Strip> {
  late final ScrollController _scroll =
      ScrollController(initialScrollOffset: widget.index * _Strip._step);

  @override
  void didUpdateWidget(_Strip old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index && _scroll.hasClients) {
      _scroll.animateTo(widget.index * _Strip._step,
          duration: Warm.quick, curve: Warm.easeOut);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('photo-viewer-strip'),
      height: _Strip._h + 6,
      child: LayoutBuilder(
        // Side room lets the first and last frames reach the centre
        builder: (context, box) => ListView.builder(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding:
              EdgeInsets.symmetric(horizontal: (box.maxWidth - _Strip._w) / 2),
          itemExtent: _Strip._step,
          itemCount: widget.records.length,
          itemBuilder: (context, i) {
            final on = i == widget.index;
            final r = widget.records[i];
            return Center(
              child: GestureDetector(
                onTap: () => widget.onPick(i),
                child: AnimatedContainer(
                  duration: Warm.quick,
                  curve: Warm.easeOut,
                  width: _Strip._w,
                  height: on ? _Strip._h + 6 : _Strip._h,
                  decoration: BoxDecoration(
                    color: const Color(0x26FFFFFF),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: on ? Colors.white : Colors.transparent,
                      width: 1.5,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: AnimatedOpacity(
                      opacity: on ? 1 : 0.55,
                      duration: Warm.quick,
                      child: r.hasThumb
                          ? EncryptedThumbnail(record: r, cache: widget.cache)
                          : const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
