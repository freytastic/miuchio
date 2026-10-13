import 'dart:convert';
import 'dart:typed_data';

import 'package:miuchio/crypto/uuid_bytes.dart';

// One row of GET /albums/{id}/media

class MediaRecord {
  final String id;
  final String albumId;
  // base64 of the raw 32B token
  final String uploaderToken;
  final Uint8List wrapNonce;
  // 16 tag + 32 ct of the DEK
  final Uint8List wrapTagCT;
  final int epochTag;
  final int blobSize;
  final Uint8List blobSha256;
  // 'photo' | 'video'
  final String mediaType;
  final String? mimeType;
  final DateTime createdAt;
  // All four set together for photos, null for videos
  final Uint8List? thumbWrapNonce;
  final Uint8List? thumbWrapTagCT;
  final int? thumbSize;
  final Uint8List? thumbSha256;
  // media_generation at confirmation, null on older rows
  final int? albumSeq;

  const MediaRecord({
    required this.id,
    required this.albumId,
    required this.uploaderToken,
    required this.wrapNonce,
    required this.wrapTagCT,
    required this.epochTag,
    required this.blobSize,
    required this.blobSha256,
    required this.mediaType,
    required this.mimeType,
    required this.createdAt,
    this.thumbWrapNonce,
    this.thumbWrapTagCT,
    this.thumbSize,
    this.thumbSha256,
    this.albumSeq,
  });

  bool get hasThumb => thumbWrapNonce != null;

  // Same shape as the server emits, persisted so a restart can decrypt offline
  Map<String, dynamic> toJson() => {
        'id': id,
        'album_id': albumId,
        'uploader_token': uploaderToken,
        'wrap_nonce': base64Encode(wrapNonce),
        'wrap_tag_ct': base64Encode(wrapTagCT),
        'epoch_tag': epochTag,
        'blob_size': blobSize,
        'blob_sha256': base64Encode(blobSha256),
        'media_type': mediaType,
        'mime_type': mimeType,
        'created_at': createdAt.toIso8601String(),
        if (thumbWrapNonce != null)
          'thumb_wrap_nonce': base64Encode(thumbWrapNonce!),
        if (thumbWrapTagCT != null)
          'thumb_wrap_tag_ct': base64Encode(thumbWrapTagCT!),
        if (thumbSize != null) 'thumb_size': thumbSize,
        if (thumbSha256 != null) 'thumb_sha256': base64Encode(thumbSha256!),
        if (albumSeq != null) 'album_seq': albumSeq,
      };

  factory MediaRecord.fromJson(Map<String, dynamic> json) {
    final thumbNonce = json['thumb_wrap_nonce'] as String?;
    final thumbTag = json['thumb_wrap_tag_ct'] as String?;
    final thumbSz = json['thumb_size'];
    final thumbSha = json['thumb_sha256'] as String?;
    return MediaRecord(
      id: json['id'] as String,
      albumId: json['album_id'] as String,
      uploaderToken: json['uploader_token'] as String,
      wrapNonce: base64Decode(json['wrap_nonce'] as String),
      wrapTagCT: base64Decode(json['wrap_tag_ct'] as String),
      epochTag: (json['epoch_tag'] as num).toInt(),
      blobSize: (json['blob_size'] as num).toInt(),
      blobSha256: base64Decode(json['blob_sha256'] as String),
      mediaType: json['media_type'] as String,
      mimeType: json['mime_type'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      thumbWrapNonce: thumbNonce == null ? null : base64Decode(thumbNonce),
      thumbWrapTagCT: thumbTag == null ? null : base64Decode(thumbTag),
      thumbSize: thumbSz == null ? null : (thumbSz as num).toInt(),
      thumbSha256: thumbSha == null ? null : base64Decode(thumbSha),
      albumSeq: (json['album_seq'] as num?)?.toInt(),
    );
  }

  Uint8List get mediaIdBytes =>
      uuidToBytes(id) ??
      (throw FormatException('media id is not a canonical UUID: $id'));

  Uint8List get albumIdBytes =>
      uuidToBytes(albumId) ??
      (throw FormatException('album id is not a canonical UUID: $albumId'));
}
