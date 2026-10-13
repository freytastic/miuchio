import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;

import 'primitives.dart';
import 'wire_format.dart';

// VER=0x03 segmented AEAD for files >= 1 MiB

//   header    VER(1) ‖ FILE_NONCE(12) ‖ SEGMENT_SIZE_BE(4)
//   segment i TAG_i(16) ‖ CT_i(<= SEGMENT_SIZE)
//   nonce_i   HKDF-SHA256(ikm=DEK, salt=FILE_NONCE, info=kSaltSegNonce ‖ u32_be(i), L=12)
//   aad_i     media_id(16) ‖ u32_be(i) ‖ u32_be(is_last)

// The index in the AAD stops reordering, is_last stops truncation (the new
// final segment was sealed with is_last=0) and media_id stops cross file swaps
abstract class AeadStream {
  static const int headerLen = 1 + kNonceLen + 4;
  static const int segmentTagLen = kTagLen;

  static Future<Uint8List> encryptBytes({
    required Uint8List dek,
    required Uint8List plaintext,
    required Uint8List mediaId,
  }) async {
    if (dek.length != 32) {
      throw ArgumentError('dek must be 32 bytes, got ${dek.length}');
    }
    if (mediaId.length != 16) {
      throw ArgumentError('mediaId must be 16 bytes, got ${mediaId.length}');
    }
    final fileNonce = Csprng.bytes(kNonceLen);

    final segments = _splitSegments(plaintext.length);
    final out = BytesBuilder(copy: false);

    final header = Uint8List(headerLen);
    header[0] = kVerStreamGcm;
    header.setRange(1, 1 + kNonceLen, fileNonce);
    ByteData.sublistView(header, 1 + kNonceLen, headerLen)
        .setUint32(0, kSegmentSize, Endian.big);
    out.add(header);

    final aes = cg.AesGcm.with256bits();
    for (var i = 0; i < segments; i++) {
      final start = i * kSegmentSize;
      final end = (start + kSegmentSize > plaintext.length)
          ? plaintext.length
          : start + kSegmentSize;
      final isLast = i == segments - 1;
      final segPlain = Uint8List.sublistView(plaintext, start, end);
      final aad = _segmentAad(mediaId, i, isLast);
      final nonce = await _segmentNonce(dek, fileNonce, i);
      final box = await aes.encrypt(
        segPlain,
        secretKey: cg.SecretKey(dek),
        nonce: nonce,
        aad: aad,
      );
      out.add(box.mac.bytes);
      out.add(box.cipherText);
    }
    return out.toBytes();
  }

  static Future<Uint8List> decryptBytes({
    required Uint8List dek,
    required Uint8List wire,
    required Uint8List mediaId,
  }) async {
    if (dek.length != 32) {
      throw ArgumentError('dek must be 32 bytes, got ${dek.length}');
    }
    if (mediaId.length != 16) {
      throw ArgumentError('mediaId must be 16 bytes, got ${mediaId.length}');
    }
    if (wire.length < headerLen) {
      throw FormatException(
          'wire too short for VER=0x03 header: ${wire.length} bytes');
    }
    if (wire[0] != kVerStreamGcm) {
      throw FormatException(
          'wire VER byte = 0x${wire[0].toRadixString(16)}, want 0x03');
    }
    final fileNonce = Uint8List.sublistView(wire, 1, 1 + kNonceLen);
    final segmentSize = ByteData.sublistView(wire, 1 + kNonceLen, headerLen)
        .getUint32(0, Endian.big);
    if (segmentSize != kSegmentSize) {
      // The header is unauthenticated, so a rewritten size must not steer parsing
      throw FormatException(
          'unexpected segment size: $segmentSize, want $kSegmentSize');
    }

    final body = Uint8List.sublistView(wire, headerLen);
    // Even an empty file has one tagged segment. A header only body would
    // decrypt to empty plaintext without verifying any tag
    if (body.isEmpty) {
      throw FormatException(
          'VER=0x03 blob has no segments: body is empty after header');
    }
    final aes = cg.AesGcm.with256bits();
    final out = BytesBuilder(copy: false);

    var cursor = 0;
    var i = 0;
    while (cursor < body.length) {
      final remaining = body.length - cursor;
      if (remaining < segmentTagLen) {
        throw FormatException(
            'segment $i truncated: ${remaining}B left, need >= $segmentTagLen');
      }
      final tag = Uint8List.sublistView(body, cursor, cursor + segmentTagLen);
      cursor += segmentTagLen;

      final ctRemaining = body.length - cursor;
      final isLast = ctRemaining <= segmentSize;
      final ctLen = isLast ? ctRemaining : segmentSize;
      if (!isLast && ctLen != segmentSize) {
        throw FormatException(
            'segment $i ct length mismatch: $ctLen, want $segmentSize');
      }
      final ct = Uint8List.sublistView(body, cursor, cursor + ctLen);
      cursor += ctLen;

      final aad = _segmentAad(mediaId, i, isLast);
      final nonce = await _segmentNonce(dek, fileNonce, i);
      try {
        final pt = await aes.decrypt(
          cg.SecretBox(ct, nonce: nonce, mac: cg.Mac(tag)),
          secretKey: cg.SecretKey(dek),
          aad: aad,
        );
        out.add(pt);
      } on cg.SecretBoxAuthenticationError catch (e) {
        throw AeadAuthFailed('segment $i: ${e.toString()}');
      }

      i++;
    }
    return out.toBytes();
  }

  // Always >= 1 so an empty file is still authenticated by its is_last segment
  static int _splitSegments(int plaintextLen) {
    if (plaintextLen == 0) return 1;
    return (plaintextLen + kSegmentSize - 1) ~/ kSegmentSize;
  }

  static Uint8List _segmentAad(Uint8List mediaId, int index, bool isLast) {
    final out = Uint8List(16 + 4 + 4);
    out.setRange(0, 16, mediaId);
    final view = ByteData.sublistView(out);
    view.setUint32(16, index, Endian.big);
    view.setUint32(20, isLast ? 1 : 0, Endian.big);
    return out;
  }

  static Future<Uint8List> _segmentNonce(
      Uint8List dek, Uint8List fileNonce, int index) async {
    final info = Uint8List(kSaltSegNonce.length + 4);
    info.setRange(0, kSaltSegNonce.length, kSaltSegNonce);
    ByteData.sublistView(info, kSaltSegNonce.length)
        .setUint32(0, index, Endian.big);
    return Hkdf.derive(
      ikm: dek,
      salt: fileNonce,
      info: info,
      length: kNonceLen,
    );
  }
}
