import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:miuchio/crypto/uuid_bytes.dart';
import 'package:miuchio/data/api/album_api.dart';
import 'package:miuchio/e2ee/album_keys.dart';
import 'package:miuchio/e2ee/sealed_name.dart';
import 'package:miuchio/ui/album/photo_sheets.dart';
import 'package:miuchio/ui/providers/app_state.dart';

// Null when the sheet was dismissed or the name left unchanged. The new title
// is sealed under the newest key this phone holds, and only shown here once
// the server has stored it
Future<bool?> renameAlbum(
  BuildContext context, {
  required String albumId,
  AlbumService? albumService,
}) async {
  final app = context.read<AppState>();
  final keys = context.read<AlbumKeyStore>();
  final name = await askAlbumName(context, app.albumDisplayName(albumId) ?? '');
  final idBytes = uuidToBytes(albumId);
  if (name == null || idBytes == null) return null;
  try {
    final epoch = await keys.latestEpoch(idBytes);
    if (epoch < 0) return false;
    final nameCt =
        await SealedName.sealAlbumName(keys, idBytes, epoch, name);
    if (!await (albumService ?? AlbumService())
        .updateAlbumNameCt(albumId, nameCt)) {
      return false;
    }
    app.applyAlbumNameCt(albumId, nameCt, name);
    return true;
  } catch (_) {
    return false;
  }
}
