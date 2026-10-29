import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/shelf/shelf_data.dart';

// The album's newest photo, from the same decrypted covers the shelf shows.
// Draws nothing until it is ready, so callers keep their own placeholder
class AlbumCover extends StatefulWidget {
  final String albumId;

  const AlbumCover({super.key, required this.albumId});

  @override
  State<AlbumCover> createState() => _AlbumCoverState();
}

class _AlbumCoverState extends State<AlbumCover> {
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
