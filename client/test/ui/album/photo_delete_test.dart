import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/data/api/api_client.dart';
import 'package:miuchio/data/api/media_api.dart';
import 'package:miuchio/data/storage/media_cache_manager.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/ui/album/photo_delete.dart';
import 'package:miuchio/ui/providers/app_state.dart';

class _GatedMediaApi extends MediaApi {
  final Completer<void> gate = Completer();
  _GatedMediaApi() : super(ApiClient());

  @override
  Future<void> deleteMedia(String albumId, String mediaId) => gate.future;

  @override
  void dispose() {}
}

class _RecordingCache implements MediaCacheManager {
  final dropped = <String>[];

  @override
  Future<void> markDeleted(String albumId, String mediaId) async =>
      dropped.add(mediaId);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

MediaRecord _shot(String id) => MediaRecord(
      id: id,
      albumId: 'album-1',
      uploaderToken: 'tok',
      wrapNonce: Uint8List(12),
      wrapTagCT: Uint8List(48),
      epochTag: 0,
      blobSize: 10,
      blobSha256: Uint8List(32),
      mediaType: 'photo',
      mimeType: 'image/jpeg',
      createdAt: DateTime.utc(2026),
    );

void main() {
  late AppState app;
  late _GatedMediaApi api;
  late _RecordingCache cache;

  setUp(() {
    app = AppState();
    api = _GatedMediaApi();
    cache = _RecordingCache();
  });

  Future<bool> delete() => deletePhoto(
      app: app,
      media: api,
      cache: cache,
      albumId: 'album-1',
      record: _shot('m1'));

  test('a delete that lands after the album closed is marked gone for good',
      () async {
    final done = delete();
    expect(app.hidesMedia('album-1', 'm1'), isTrue,
        reason: 'hidden before the server answers');

    // No screen is involved from here on
    api.gate.complete();
    expect(await done, isTrue);
    expect(cache.dropped, ['m1']);
    expect(app.hidesMedia('album-1', 'm1'), isTrue,
        reason: 'stays hidden from listings that raced the delete');
  });

  test('a refused delete shows the photo again and keeps its saved copy',
      () async {
    final done = delete();
    api.gate.completeError(Exception('offline'));

    expect(await done, isFalse);
    expect(app.hidesMedia('album-1', 'm1'), isFalse);
    expect(cache.dropped, isEmpty);
  });
}
