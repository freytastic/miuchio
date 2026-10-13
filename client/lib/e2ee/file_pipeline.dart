import 'dart:typed_data';

import 'package:miuchio/crypto/aead_stream.dart';
import 'package:miuchio/crypto/blob_digest.dart';
import 'package:miuchio/crypto/primitives.dart';
import 'package:miuchio/crypto/uuid_bytes.dart';
import 'package:miuchio/crypto/wire_format.dart';
import 'package:miuchio/diagnostics/aes_path.dart';
import 'package:miuchio/diagnostics/trace.dart';
import 'package:uuid/uuid.dart';

import 'album_keys.dart';
import 'photo_clean.dart';

export 'photo_clean.dart';

// Upload encryption

//   file   fresh DEK, AAD = media_id, VER=0x01 below 1 MiB else VER=0x03
//   thumb  its own DEK, AAD = media_id || "thumb" so the two can't be swapped
//   wraps  both DEKs sealed under the album MK, AAD = album_id || u32_be(epoch)

// MK bytes never leave AlbumKeyStore.useMk. prepareUpload zeroes the DEKs
// itself, but wrapKeys leaves them alive so the same media can be wrapped
// again, so callers using encryptMedia and wrapKeys directly own zeroKeys

const int _wrapNonceLen = 12;
// 16 tag + 32 ct(DEK)
const int _wrapTagCTLen = 48;
const int _wrapWireLen = 1 + _wrapNonceLen + _wrapTagCTLen;
const int _dekLen = 32;
const int _mediaIdLen = 16;

final Uint8List _kThumbAadSuffix = Uint8List.fromList('thumb'.codeUnits);

class UploadEnvelope {
  final Uint8List mediaId;
  final Uint8List cipherBytes;
  final Uint8List wrapNonce;
  // TAG ‖ AES-GCM(MK, DEK)
  final Uint8List wrapTagCT;
  final int epoch;
  final int blobSize;
  final Uint8List blobSha256;
  // 'photo' or 'video'
  final String mediaType;
  final String? mimeType;
  // Null only for videos, an undecodable photo fails closed before this
  final Uint8List? thumbCipherBytes;
  final Uint8List? thumbWrapNonce;
  final Uint8List? thumbWrapTagCT;
  final Uint8List? thumbSha256;
  // Plaintext kept only in memory to seed the post upload cache
  final Uint8List? filePlaintext;
  final Uint8List? thumbPlaintext;

  const UploadEnvelope({
    required this.mediaId,
    required this.cipherBytes,
    required this.wrapNonce,
    required this.wrapTagCT,
    required this.epoch,
    required this.blobSize,
    required this.blobSha256,
    required this.mediaType,
    required this.mimeType,
    this.filePlaintext,
    this.thumbCipherBytes,
    this.thumbWrapNonce,
    this.thumbWrapTagCT,
    this.thumbSha256,
    this.thumbPlaintext,
  });

  bool get hasThumb => thumbCipherBytes != null;
  int get thumbSize => thumbCipherBytes?.length ?? 0;

  String get mediaIdString => uuidFromBytes(mediaId);
}

// Media encrypted under fresh DEKs but not yet bound to an album key
class EncryptedMedia {
  final Uint8List mediaId;
  final Uint8List cipherBytes;
  final Uint8List blobSha256;
  final Uint8List dek;
  final String mediaType;
  final String? mimeType;
  final Uint8List? thumbCipherBytes;
  final Uint8List? thumbSha256;
  final Uint8List? thumbDek;
  final Uint8List? filePlaintext;
  final Uint8List? thumbPlaintext;

  const EncryptedMedia({
    required this.mediaId,
    required this.cipherBytes,
    required this.blobSha256,
    required this.dek,
    required this.mediaType,
    required this.mimeType,
    this.thumbCipherBytes,
    this.thumbSha256,
    this.thumbDek,
    this.filePlaintext,
    this.thumbPlaintext,
  });

  int get payloadByteLength =>
      cipherBytes.length + (thumbCipherBytes?.length ?? 0);

  void zeroKeys() {
    dek.fillRange(0, dek.length, 0);
    final t = thumbDek;
    if (t != null) t.fillRange(0, t.length, 0);
  }

  void zeroAll() {
    zeroKeys();
    for (final b in [filePlaintext, thumbPlaintext]) {
      if (b != null) b.fillRange(0, b.length, 0);
    }
  }
}

abstract class FilePipeline {
  // Encrypts with fresh DEKs, wraps them under the current MK, then zeroes them
  static Future<UploadEnvelope> prepareUpload({
    required AlbumKeyStore aks,
    required Uint8List albumIdBytes,
    required int currentEpoch,
    required Uint8List plaintext,
    required String mediaType,
    String? mimeType,
    // Stable across retries because media ID is AEAD AAD
    Uint8List? mediaId,
    ImageTranscoder? transcode,
  }) async {
    if (albumIdBytes.length != _mediaIdLen) {
      throw ArgumentError(
          'albumIdBytes must be 16 bytes, got ${albumIdBytes.length}');
    }
    final span = Trace.start('media.prepareUpload', fields: {
      'kind': mediaType,
      'input_bytes': plaintext.length,
      'epoch': currentEpoch,
    });
    try {
      final media = await encryptMedia(
        plaintext: plaintext,
        mediaType: mediaType,
        mimeType: mimeType,
        mediaId: mediaId,
        transcode: transcode,
      );
      try {
        final env = await wrapKeys(
          aks: aks,
          albumIdBytes: albumIdBytes,
          epoch: currentEpoch,
          media: media,
        );
        span.end(fields: {
          'file_bytes': env.blobSize,
          'thumb_bytes': env.thumbSize,
        });
        return env;
      } finally {
        media.zeroKeys();
      }
    } catch (e) {
      span.fail(Trace.reasonOf(e));
      rethrow;
    }
  }

  // Needs no album key because the file AAD is only the media id
  static Future<EncryptedMedia> encryptMedia({
    required Uint8List plaintext,
    required String mediaType,
    String? mimeType,
    Uint8List? mediaId,
    ImageTranscoder? transcode,
  }) async {
    if (mediaType != 'photo' && mediaType != 'video') {
      throw ArgumentError(
          "mediaType must be 'photo' or 'video', got $mediaType");
    }
    if (mediaId != null && mediaId.length != _mediaIdLen) {
      throw ArgumentError('mediaId must be 16 bytes, got ${mediaId.length}');
    }
    final id = mediaId ?? uuidToBytes(const Uuid().v4())!;
    final traceFields = <String, Object?>{
      'media': Trace.id(uuidFromBytes(id)),
      'kind': mediaType,
      'input_bytes': plaintext.length,
    };
    final dek = Csprng.bytes(_dekLen);
    Uint8List? dekThumb;
    try {
      // Undecodable photos fail closed, videos keep their original bytes
      Uint8List bytesToEncrypt = plaintext;
      Uint8List? thumbPlaintext;
      if (mediaType == 'photo') {
        final clean = await cleanPhoto(plaintext,
            transcode: transcode, traceFields: traceFields);
        bytesToEncrypt = clean.jpeg;
        thumbPlaintext = clean.thumb;
      }

      final cipher = await Trace.measure<Uint8List>(
        'media.fileEncrypt',
        () => bytesToEncrypt.length < kSegmentSize
            ? Aead.encrypt(
                version: kVerAesGcm,
                key: dek,
                plaintext: bytesToEncrypt,
                aad: id,
              )
            : AeadStream.encryptBytes(
                dek: dek,
                plaintext: bytesToEncrypt,
                mediaId: id,
              ),
        fields: {
          ...traceFields,
          'bytes': bytesToEncrypt.length,
          'mode': bytesToEncrypt.length < kSegmentSize ? 'single' : 'stream',
          if (Trace.enabled)
            'path': aesPath(bytesToEncrypt.length < kSegmentSize
                ? bytesToEncrypt.length
                : kSegmentSize),
        },
        endFields: (result) => {'output_bytes': result.length},
      );

      Uint8List? thumbCipher;
      Uint8List? thumbSha256;
      if (thumbPlaintext != null) {
        dekThumb = Csprng.bytes(_dekLen);
        final ct = await Aead.encrypt(
          version: kVerAesGcm,
          key: dekThumb,
          plaintext: thumbPlaintext,
          aad: _thumbAad(id),
        );
        thumbCipher = ct;
        thumbSha256 = await Trace.measure<Uint8List>(
          'media.hashThumb',
          () => _sha256(ct),
          fields: {...traceFields, 'bytes': ct.length},
        );
      }

      return EncryptedMedia(
        mediaId: id,
        cipherBytes: cipher,
        blobSha256: await Trace.measure<Uint8List>(
          'media.hashFile',
          () => _sha256(cipher),
          fields: {...traceFields, 'bytes': cipher.length},
        ),
        dek: dek,
        mediaType: mediaType,
        mimeType: mediaType == 'photo' ? 'image/jpeg' : mimeType,
        thumbCipherBytes: thumbCipher,
        thumbSha256: thumbSha256,
        thumbDek: dekThumb,
        filePlaintext: bytesToEncrypt,
        thumbPlaintext: thumbPlaintext,
      );
    } catch (_) {
      dek.fillRange(0, dek.length, 0);
      dekThumb?.fillRange(0, dekThumb.length, 0);
      rethrow;
    }
  }

  // Keeps MK bytes inside one useMk callback while wrapping both DEKs
  static Future<UploadEnvelope> wrapKeys({
    required AlbumKeyStore aks,
    required Uint8List albumIdBytes,
    required int epoch,
    required EncryptedMedia media,
  }) async {
    if (albumIdBytes.length != _mediaIdLen) {
      throw ArgumentError(
          'albumIdBytes must be 16 bytes, got ${albumIdBytes.length}');
    }
    final wrapAad = _wrapAad(albumIdBytes, epoch);
    final thumbDek = media.thumbCipherBytes == null ? null : media.thumbDek;
    late final Uint8List wrapNonce;
    late final Uint8List wrapTagCT;
    Uint8List? thumbWrapNonce;
    Uint8List? thumbWrapTagCT;
    await Trace.measure<void>(
      'media.keyWrap',
      () => aks.useMk<void>(albumIdBytes, epoch, (mk) async {
        final wrapWire = await Aead.encrypt(
          version: kVerAesGcm,
          key: mk,
          plaintext: media.dek,
          aad: wrapAad,
        );
        if (wrapWire.length != _wrapWireLen) {
          throw StateError(
              'wrap wire length = ${wrapWire.length}, want $_wrapWireLen');
        }
        wrapNonce = Uint8List.fromList(wrapWire.sublist(1, 1 + _wrapNonceLen));
        wrapTagCT = Uint8List.fromList(wrapWire.sublist(1 + _wrapNonceLen));

        if (thumbDek != null) {
          final thumbWrapWire = await Aead.encrypt(
            version: kVerAesGcm,
            key: mk,
            plaintext: thumbDek,
            aad: wrapAad,
          );
          thumbWrapNonce =
              Uint8List.fromList(thumbWrapWire.sublist(1, 1 + _wrapNonceLen));
          thumbWrapTagCT =
              Uint8List.fromList(thumbWrapWire.sublist(1 + _wrapNonceLen));
        }
      }),
      fields: {
        'media': Trace.id(uuidFromBytes(media.mediaId)),
        'epoch': epoch,
        'wraps': thumbDek == null ? 1 : 2,
      },
    );

    return UploadEnvelope(
      mediaId: media.mediaId,
      cipherBytes: media.cipherBytes,
      wrapNonce: wrapNonce,
      wrapTagCT: wrapTagCT,
      epoch: epoch,
      blobSize: media.cipherBytes.length,
      blobSha256: media.blobSha256,
      mediaType: media.mediaType,
      mimeType: media.mimeType,
      filePlaintext: media.filePlaintext,
      thumbCipherBytes: thumbDek == null ? null : media.thumbCipherBytes,
      thumbWrapNonce: thumbWrapNonce,
      thumbWrapTagCT: thumbWrapTagCT,
      thumbSha256: thumbDek == null ? null : media.thumbSha256,
      thumbPlaintext: media.thumbPlaintext,
    );
  }

  static Future<Uint8List?> openThumb(EncryptedMedia media) async {
    final cipher = media.thumbCipherBytes;
    final dek = media.thumbDek;
    if (cipher == null || dek == null) return null;
    return openThumbCipher(mediaId: media.mediaId, cipher: cipher, dek: dek);
  }

  static Future<Uint8List> openThumbCipher({
    required Uint8List mediaId,
    required Uint8List cipher,
    required Uint8List dek,
  }) =>
      Aead.decrypt(wire: cipher, key: dek, aad: _thumbAad(mediaId));
}

Uint8List _wrapAad(Uint8List albumIdBytes, int epoch) {
  final out = Uint8List(_mediaIdLen + 4);
  out.setRange(0, _mediaIdLen, albumIdBytes);
  ByteData.sublistView(out, _mediaIdLen).setUint32(0, epoch, Endian.big);
  return out;
}

Uint8List _thumbAad(Uint8List mediaId) {
  final out = Uint8List(mediaId.length + _kThumbAadSuffix.length);
  out.setRange(0, mediaId.length, mediaId);
  out.setRange(mediaId.length, out.length, _kThumbAadSuffix);
  return out;
}

Future<Uint8List> _sha256(Uint8List bytes) => BlobDigest.sha256(bytes);
