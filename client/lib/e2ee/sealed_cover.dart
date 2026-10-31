import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:miuchio/crypto/primitives.dart';
import 'package:miuchio/crypto/uuid_bytes.dart';
import 'package:miuchio/crypto/wire_format.dart';
import 'package:uuid/uuid.dart';

import 'album_keys.dart';
import 'mk_seal.dart';

// Every cover is padded to one size so its object says nothing about the image
const int kCoverPaddedBytes = 384 * 1024;
const int kCoverMaxJpegBytes = kCoverPaddedBytes - 4;

const int _dekLen = 32;

class SealedCover {
  final String coverId;
  final Uint8List blob;
  final Uint8List blobSha256;
  // MkSeal wire around the per cover DEK
  final Uint8List keyCt;

  const SealedCover({
    required this.coverId,
    required this.blob,
    required this.blobSha256,
    required this.keyCt,
  });
}

// A cover chosen from outside the album, sealed like an avatar but bound to
// the album alone, so the server cannot move it onto another album
//   blob   = Aead(DEK, u32_be(len) || jpeg || zeros, aad = tag || album || cover_id)
//   key_ct = MkSeal(MK_epoch, DEK, aad = key tag || album || cover_id || u32_be(epoch))
abstract class CoverCrypto {
  static final Uint8List _blobTag =
      Uint8List.fromList('miuchio.cover-v1'.codeUnits);
  static final Uint8List _keyTag =
      Uint8List.fromList('miuchio.cover-key-v1'.codeUnits);

  // Sealed under the album's newest MK
  static Future<SealedCover> seal({
    required AlbumKeyStore ks,
    required Uint8List albumId,
    required Uint8List jpeg,
  }) async {
    final epoch = await ks.latestEpoch(albumId);
    if (epoch < 0) throw StateError('no album key to seal a cover under');
    final coverId = uuidToBytes(const Uuid().v4())!;
    final dek = Csprng.bytes(_dekLen);
    final padded = _pad(jpeg);
    try {
      final blob = await Aead.encrypt(
        version: kVerAesGcm,
        key: dek,
        plaintext: padded,
        aad: _concat([_blobTag, albumId, coverId]),
      );
      final keyCt = await MkSeal.seal(
          ks, albumId, epoch, dek, (e) => _keyAad(albumId, coverId, e));
      return SealedCover(
        coverId: uuidFromBytes(coverId),
        blob: blob,
        blobSha256: await _sha256(blob),
        keyCt: keyCt,
      );
    } finally {
      dek.fillRange(0, dek.length, 0);
      padded.fillRange(0, padded.length, 0);
    }
  }

  // Null when the blob does not match its hash, the MK is missing, or either
  // AEAD layer refuses it
  static Future<Uint8List?> open({
    required AlbumKeyStore ks,
    required Uint8List albumId,
    required String coverId,
    required Uint8List keyCt,
    required Uint8List blobSha256,
    required Uint8List blob,
  }) async {
    final id = uuidToBytes(coverId);
    if (id == null || !_eq(await _sha256(blob), blobSha256)) return null;
    final dek =
        await MkSeal.open(ks, albumId, keyCt, (e) => _keyAad(albumId, id, e));
    if (dek == null || dek.length != _dekLen) return null;
    try {
      final padded = await Aead.decrypt(
          wire: blob, key: dek, aad: _concat([_blobTag, albumId, id]));
      return _unpad(padded);
    } on AeadAuthFailed {
      return null;
    } on FormatException {
      return null;
    } finally {
      dek.fillRange(0, dek.length, 0);
    }
  }

  static Uint8List _pad(Uint8List jpeg) {
    if (jpeg.isEmpty || jpeg.length > kCoverMaxJpegBytes) {
      throw ArgumentError('cover jpeg must be 1..$kCoverMaxJpegBytes bytes, '
          'got ${jpeg.length}');
    }
    final out = Uint8List(kCoverPaddedBytes);
    ByteData.sublistView(out, 0, 4).setUint32(0, jpeg.length, Endian.big);
    out.setRange(4, 4 + jpeg.length, jpeg);
    return out;
  }

  static Uint8List? _unpad(Uint8List padded) {
    if (padded.length != kCoverPaddedBytes) return null;
    final n = ByteData.sublistView(padded, 0, 4).getUint32(0, Endian.big);
    if (n == 0 || n > kCoverMaxJpegBytes) return null;
    return Uint8List.fromList(Uint8List.sublistView(padded, 4, 4 + n));
  }

  static Uint8List _keyAad(Uint8List albumId, Uint8List coverId, int epoch) {
    final e = Uint8List(4);
    ByteData.sublistView(e).setUint32(0, epoch, Endian.big);
    return _concat([_keyTag, albumId, coverId, e]);
  }
}

Future<Uint8List> _sha256(Uint8List bytes) async =>
    Uint8List.fromList((await cg.Sha256().hash(bytes)).bytes);

bool _eq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

Uint8List _concat(List<Uint8List> parts) {
  final out = BytesBuilder(copy: false);
  for (final p in parts) {
    out.add(p);
  }
  return out.toBytes();
}
