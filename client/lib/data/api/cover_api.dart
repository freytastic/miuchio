import 'dart:convert';
import 'dart:typed_data';

import 'package:miuchio/data/models/cover_ref.dart';
import 'package:miuchio/e2ee/sealed_cover.dart';

import 'api_client.dart';
import 's3_transport.dart';

// Owner only. An upload is reserved, PUT and confirmed, and the server swaps
// it in only after checking the stored object against the reservation
class CoverApi {
  final ApiClient _api;
  final S3Transport _s3;

  CoverApi(this._api, {S3Transport? transport})
      : _s3 = transport ?? S3Transport();

  // Null goes back to the newest photo
  Future<void> choosePhoto(String albumId, String? mediaId) =>
      _api.put('/albums/$albumId/cover', body: {'media_id': mediaId});

  Future<void> upload(String albumId, SealedCover cover) async {
    final resp = await _api.post('/albums/$albumId/cover/upload-url', body: {
      'cover_id': cover.coverId,
      'blob_size': cover.blob.length,
      'blob_sha256': base64Encode(cover.blobSha256),
      'key_ct': base64Encode(cover.keyCt),
    });
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final headers = (json['required_header'] as Map<String, dynamic>? ?? {})
        .map((k, v) => MapEntry(k, v.toString()));
    final put = await _s3.put(
        Uri.parse(json['upload_url'] as String), cover.blob, headers,
        traceFields: const {'kind': 'cover'});
    if (put.statusCode < 200 || put.statusCode >= 300) {
      throw S3StatusException(put.statusCode);
    }
    await _api.post('/albums/$albumId/cover/confirm',
        body: {'cover_id': cover.coverId});
  }

  Future<Uint8List> download(String albumId, CoverRef ref) async {
    Future<Uri> url() async {
      final resp = await _api
          .post('/albums/$albumId/covers/${ref.coverId}/download-url');
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      return Uri.parse(json['url'] as String);
    }

    final resp = await _s3.get(await url(),
        expectedBytes: ref.blobSize,
        traceFields: const {'kind': 'cover'},
        refreshUrl: url);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw S3StatusException(resp.statusCode);
    }
    return resp.bodyBytes;
  }

  void dispose() => _s3.close();
}
