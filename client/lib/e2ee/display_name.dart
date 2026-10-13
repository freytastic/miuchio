import 'dart:convert';
import 'dart:typed_data';

import 'package:miuchio/crypto/uuid_bytes.dart';
import 'package:miuchio/crypto/wire_format.dart';
import 'package:miuchio/e2ee/album_keys.dart';
import 'package:miuchio/e2ee/sealed_name.dart';

// The server resolves the caller's member_token itself
typedef PutProfileCt = Future<void> Function(String albumId, String nameCtB64);

// memberToken is only for the AAD, it is never sent
typedef NameTarget = ({String albumId, Uint8List memberToken});

class DisplayNamePublisher {
  final AlbumKeyStore _ks;
  final PutProfileCt _putProfileCt;

  DisplayNamePublisher({
    required AlbumKeyStore ks,
    required PutProfileCt putProfileCt,
  })  : _ks = ks,
        _putProfileCt = putProfileCt;

  // No op when the name is empty or the album has no MK yet
  Future<void> publishToAlbum({
    required String albumId,
    required Uint8List memberToken,
    required String name,
  }) async {
    if (name.isEmpty) return;
    final idBytes = uuidToBytes(albumId);
    if (idBytes == null) return;
    final epoch = await _ks.latestEpoch(idBytes);
    if (epoch < 0) return;
    final ct =
        await SealedName.sealMemberName(_ks, idBytes, memberToken, epoch, name);
    await _putProfileCt(albumId, ct);
  }

  // Best effort, one album failing doesn't stop the rest
  Future<void> publishToAll(Iterable<NameTarget> targets, String name) async {
    if (name.isEmpty) return;
    for (final t in targets) {
      try {
        await publishToAlbum(
            albumId: t.albumId, memberToken: t.memberToken, name: name);
      } catch (_) {}
    }
  }
}

// Also reads the legacy base64(utf8(name)) placeholder
Future<String> resolveAlbumName(
    AlbumKeyStore ks, Uint8List albumId, String? nameCtB64) async {
  if (nameCtB64 == null || nameCtB64.isEmpty) return 'Untitled Album';
  final opened = await SealedName.openAlbumName(ks, albumId, nameCtB64);
  if (opened != null) return opened;
  // A sealed title whose MK isn't installed yet also lands here, decoding it
  // as legacy text would flash mojibake
  Uint8List raw;
  try {
    raw = base64.decode(nameCtB64);
  } catch (_) {
    return 'Untitled Album';
  }
  if (!_looksSealed(raw)) {
    try {
      final decoded = utf8.decode(raw, allowMalformed: false);
      if (decoded.isNotEmpty) return decoded;
    } catch (_) {}
  }
  return 'Untitled Album';
}

bool _looksSealed(Uint8List raw) {
  if (raw.length < 4 + kHeaderLen) return false;
  final ver = raw[4];
  return ver == kVerAesGcm || ver == kVerChaPo || ver == kVerStreamGcm;
}
