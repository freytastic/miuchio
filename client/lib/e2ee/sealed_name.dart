import 'dart:convert';
import 'dart:typed_data';

import 'package:miuchio/crypto/primitives.dart';
import 'package:miuchio/e2ee/album_keys.dart';
import 'package:miuchio/e2ee/mk_seal.dart';

// Album titles and member names sealed under the album MK

//   name_ct = base64(u32_be(epoch) || VER||NONCE||TAG||CT)

// The epoch travels in the blob so readers know which MK to use. The AAD binds
// each blob to its slot so a name can't be replayed into another
class SealedName {
  static final Uint8List _albumTag =
      Uint8List.fromList('miuchio.album-name-v1'.codeUnits);
  static final Uint8List _memberTag =
      Uint8List.fromList('miuchio.member-name-v1'.codeUnits);

  static Future<String> sealAlbumName(
      AlbumKeyStore ks, Uint8List albumId, int epoch, String name) {
    return _seal(ks, albumId, epoch, name, _albumNameAad(albumId, epoch));
  }

  static Future<String> sealMemberName(AlbumKeyStore ks, Uint8List albumId,
      Uint8List memberToken, int epoch, String name) {
    return _seal(
        ks, albumId, epoch, name, _memberNameAad(albumId, memberToken, epoch));
  }

  // Null on any failure, callers render a fallback
  static Future<String?> openAlbumName(
      AlbumKeyStore ks, Uint8List albumId, String nameCtB64) {
    return _open(
        ks, albumId, nameCtB64, (epoch) => _albumNameAad(albumId, epoch));
  }

  static Future<String?> openMemberName(AlbumKeyStore ks, Uint8List albumId,
      Uint8List memberToken, String nameCtB64) {
    return _open(ks, albumId, nameCtB64,
        (epoch) => _memberNameAad(albumId, memberToken, epoch));
  }

  // One keystore read per epoch instead of per member. Entries that fail to
  // open are left out
  static Future<Map<String, String>> openMemberNames(
    AlbumKeyStore ks,
    Uint8List albumId,
    List<({String token, Uint8List tokenBytes, String nameCt})> items,
  ) async {
    final byEpoch =
        <int, List<({String token, Uint8List tokenBytes, Uint8List blob})>>{};
    for (final it in items) {
      Uint8List wire;
      try {
        wire = base64.decode(it.nameCt);
      } catch (_) {
        continue;
      }
      final epoch = MkSeal.epochOf(wire);
      if (epoch == null) continue;
      byEpoch.putIfAbsent(epoch, () => []).add((
        token: it.token,
        tokenBytes: it.tokenBytes,
        blob: MkSeal.body(wire),
      ));
    }

    final out = <String, String>{};
    for (final entry in byEpoch.entries) {
      final epoch = entry.key;
      try {
        await ks.useMk<void>(albumId, epoch, (mk) async {
          for (final p in entry.value) {
            final aad = _memberNameAad(albumId, p.tokenBytes, epoch);
            try {
              final pt = await Aead.decrypt(wire: p.blob, key: mk, aad: aad);
              out[p.token] = utf8.decode(pt);
            } catch (_) {}
          }
        });
      } catch (_) {}
    }
    return out;
  }

  static Future<String> _seal(AlbumKeyStore ks, Uint8List albumId, int epoch,
      String name, Uint8List aad) async {
    final pt = Uint8List.fromList(utf8.encode(name));
    return base64.encode(await MkSeal.seal(ks, albumId, epoch, pt, (_) => aad));
  }

  static Future<String?> _open(AlbumKeyStore ks, Uint8List albumId,
      String nameCtB64, Uint8List Function(int epoch) aadFor) async {
    try {
      final pt =
          await MkSeal.open(ks, albumId, base64.decode(nameCtB64), aadFor);
      return pt == null ? null : utf8.decode(pt);
    } on FormatException {
      return null;
    }
  }

  static Uint8List _albumNameAad(Uint8List albumId, int epoch) {
    return _concat([_albumTag, albumId, _u32be(epoch)]);
  }

  static Uint8List _memberNameAad(
      Uint8List albumId, Uint8List memberToken, int epoch) {
    return _concat([_memberTag, albumId, memberToken, _u32be(epoch)]);
  }
}

Uint8List _u32be(int v) {
  final b = Uint8List(4);
  ByteData.sublistView(b).setUint32(0, v, Endian.big);
  return b;
}

Uint8List _concat(List<Uint8List> parts) {
  var len = 0;
  for (final p in parts) {
    len += p.length;
  }
  final out = Uint8List(len);
  var off = 0;
  for (final p in parts) {
    out.setRange(off, off + p.length, p);
    off += p.length;
  }
  return out;
}
