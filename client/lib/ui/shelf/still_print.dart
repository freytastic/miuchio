import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:miuchio/data/models/album_model.dart';
import 'package:miuchio/data/storage/cover_cache.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/shelf/album_print.dart';
import 'package:miuchio/ui/shelf/shelf_data.dart';
import 'package:provider/provider.dart';

// The print's photos in order. An uploaded cover leads and the album's own
// previews follow, until it opens the newest photo stands in
Uint8List? printPhoto(BuildContext context, AlbumModel album, int slot) {
  final covers = context.read<ShelfCovers?>();
  final cover = album.cover;
  if (cover == null || !cover.isUpload) return covers?.bytes(album.id, slot);
  if (slot > 0) return covers?.bytes(album.id, slot - 1);
  final cache = context.read<CoverCache?>();
  cache?.ensure(album.id, cover);
  return cache?.peek(album.id, cover.coverId) ?? covers?.bytes(album.id, 0);
}

// An album's print away from the shelf: the same cover, title and faces, but
// nothing to hold or fan
class StillPrint extends StatelessWidget {
  final AlbumModel album;
  final PrintSize size;
  final VoidCallback? onTap;

  const StillPrint({
    super.key,
    required this.album,
    this.size = PrintSize.large,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    context.watch<ShelfCovers?>();
    context.watch<CoverCache?>();
    if (album.previewMedia.isNotEmpty) {
      context.read<ShelfCovers?>()?.ensureCover(album.id, album.previewMedia);
    }
    Widget? image(int slot) {
      final bytes = printPhoto(context, album, slot);
      return bytes == null
          ? null
          : Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
    }

    return AlbumPrint(
      albumId: album.id,
      title: state.albumDisplayName(album.id),
      mediaCount: album.mediaCount,
      unseen: 0,
      lastActivity: album.latestActivityAt,
      members: album.memberPreviews,
      totalMembers: album.activeMemberCount,
      nameOf: (m) => state.memberDisplayName(album.id, m.memberToken),
      develop: kAlwaysCompleteAnimation,
      size: size,
      cover: image(0),
      behind: [image(1), image(2)].nonNulls.toList(),
      onTap: onTap,
    );
  }
}
