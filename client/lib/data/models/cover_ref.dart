import 'dart:convert';
import 'dart:typed_data';

// The cover the album owner chose. A chosen photo carries only its media id,
// an uploaded cover its sealed key and no storage coordinates
class CoverRef {
  final String coverId;
  // Member token of whoever set it
  final String setBy;
  final String? mediaId;
  final int blobSize;
  final Uint8List? blobSha256;
  final Uint8List? keyCt;

  const CoverRef({
    required this.coverId,
    required this.setBy,
    this.mediaId,
    this.blobSize = 0,
    this.blobSha256,
    this.keyCt,
  });

  bool get isUpload => mediaId == null;

  Map<String, dynamic> toJson() => {
        'cover_id': coverId,
        'set_by': setBy,
        if (mediaId != null) 'media_id': mediaId,
        if (isUpload) ...{
          'blob_size': blobSize,
          'blob_sha256': base64.encode(blobSha256!),
          'key_ct': base64.encode(keyCt!),
        },
      };

  static CoverRef? tryFromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    try {
      Uint8List b(String k) =>
          base64.decode(base64.normalize(json[k] as String));
      final mediaId = json['media_id'] as String?;
      return CoverRef(
        coverId: json['cover_id'] as String,
        setBy: json['set_by'] as String,
        mediaId: mediaId,
        blobSize: mediaId == null ? (json['blob_size'] as num).toInt() : 0,
        blobSha256: mediaId == null ? b('blob_sha256') : null,
        keyCt: mediaId == null ? b('key_ct') : null,
      );
    } catch (_) {
      return null;
    }
  }
}
