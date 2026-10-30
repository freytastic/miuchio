import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:miuchio/data/api/album_api.dart';
import 'package:miuchio/data/api/api_client.dart';
import 'package:miuchio/data/api/media_api.dart';
import 'package:miuchio/data/models/album_model.dart';
import 'package:miuchio/data/models/member_model.dart';
import 'package:miuchio/data/storage/media_cache_manager.dart';
import 'package:miuchio/data/storage/media_plaintext_cache.dart';
import 'package:miuchio/data/storage/media_sealed_cache.dart';
import 'package:miuchio/e2ee/album_keys.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/ui/album/album_copy.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/screens/album_detail_screen.dart';
import 'package:miuchio/ui/widgets/encrypted_thumbnail.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../secure_store/mock_secure_key_store.dart';

import 'package:miuchio/ui/providers/upload_queue_model.dart';
import 'upload_scaffold.dart';

class _MockAlbumService extends AlbumService {
  @override
  Future<List<AlbumMember>> listMembers(String albumId) async => [];
}

class _StubMediaApi extends MediaApi {
  final List<MediaRecord> items;
  final deleted = <String>[];

  _StubMediaApi(this.items) : super(ApiClient());

  @override
  Future<List<MediaRecord>> listMedia(String _) async => items;

  @override
  Future<void> deleteMedia(String albumId, String mediaId) async =>
      deleted.add(mediaId);

  @override
  void dispose() {}
}

MediaRecord _rec(String id, String uploader) => MediaRecord(
      id: id,
      albumId: 'album-1',
      uploaderToken: uploader,
      wrapNonce: Uint8List(12),
      wrapTagCT: Uint8List(48),
      epochTag: 0,
      blobSize: 10,
      blobSha256: Uint8List(32),
      mediaType: 'photo',
      mimeType: 'image/jpeg',
      createdAt: DateTime.utc(2026),
    );

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AlbumKeyStore aks;
  late Directory dir;
  late MediaSealedCache sealed;

  setUp(() async {
    final store = MockSecureKeyStore();
    await store.initialize();
    aks = AlbumKeyStore(store);
    await aks.initialize();
    dir = await Directory.systemTemp.createTemp('miuchio_select');
    sealed =
        await MediaSealedCache.open(rootDir: dir, cacheRootKey: Uint8List(32));
  });

  tearDown(() async {
    await sealed.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Widget wrap(_StubMediaApi api) => MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AppState()),
          Provider<AlbumKeyStore>.value(value: aks),
          ChangeNotifierProvider<UploadQueueModel>.value(
              value: idleUploadQueue()),
          Provider<MediaCacheManager>.value(
            value: MediaCacheManager(
              plaintext: MediaPlaintextCache(),
              ciphertext: sealed,
              api: api,
              aks: aks,
            ),
          ),
        ],
        child: MaterialApp(
          home: AlbumDetailScreen(
            album: AlbumModel(
              id: 'album-1',
              nameCt: null,
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
              memberToken: 'me',
            ),
            albumService: _MockAlbumService(),
            mediaApi: api,
          ),
        ),
      );

  Finder tile(int i) => find.byType(EncryptedThumbnail).at(i);

  testWidgets('select mode deletes only your own photos', (tester) async {
    final api = _StubMediaApi(
        [_rec('a', 'me'), _rec('b', 'them'), _rec('c', 'me')]);
    await tester.pumpWidget(wrap(api));
    await settle(tester);

    await tester.tap(find.byKey(const Key('album-select')));
    await tester.pump();
    await tester.tap(tile(0));
    await tester.tap(tile(1));
    await tester.pump();

    expect(find.text('2 selected · 1 yours'), findsOneWidget);
    expect(find.text('Delete 1 of 2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('select-delete')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.textContaining("The other one isn't yours"), findsOneWidget);

    await tester.tap(find.byKey(const Key('select-delete-confirm')));
    await tester.pump();
    // The deleted mark is a real SQLite write, which fake time never settles
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await settle(tester);

    expect(api.deleted, ['a'], reason: "someone else's photo is never sent");
    expect(find.byKey(const Key('select-delete')), findsNothing,
        reason: 'select mode ends once the delete starts');
  });

  testWidgets('a sideways slide selects a run without tapping Select',
      (tester) async {
    final api = _StubMediaApi(
        [_rec('a', 'me'), _rec('b', 'them'), _rec('c', 'me')]);
    await tester.pumpWidget(wrap(api));
    await settle(tester);

    final gesture = await tester.startGesture(tester.getCenter(tile(0)));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(tile(2)));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(find.text('3 selected · 2 yours'), findsOneWidget);
    expect(find.text('Delete 2 of 3'), findsOneWidget);
  });

  testWidgets('back leaves select mode before it leaves the album',
      (tester) async {
    final api = _StubMediaApi([_rec('a', 'them')]);
    await tester.pumpWidget(wrap(api));
    await settle(tester);

    await tester.tap(find.byKey(const Key('album-select')));
    await tester.pump();
    await tester.tap(tile(0));
    await tester.pump();
    expect(find.text('1 selected · none yours'), findsOneWidget);
    expect(find.text(AlbumCopy.deleteSelected(1, 0)), findsOneWidget);

    await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
    await tester.pump();

    expect(find.byKey(const Key('select-delete')), findsNothing);
    expect(find.byType(AlbumDetailScreen), findsOneWidget);
  });

  testWidgets('the top bar selects everything and closes select mode',
      (tester) async {
    final api = _StubMediaApi([_rec('a', 'me'), _rec('b', 'them')]);
    await tester.pumpWidget(wrap(api));
    await settle(tester);

    await tester.tap(find.byKey(const Key('album-select')));
    await settle(tester); // the bar slides in
    await tester.tap(find.byKey(const Key('select-all')));
    await tester.pump();
    expect(find.text('2 selected · 1 yours'), findsOneWidget);
    expect(find.text(AlbumCopy.selectNone), findsOneWidget);

    await tester.tap(find.byKey(const Key('select-close')));
    await settle(tester);
    expect(find.byKey(const Key('select-delete')), findsNothing);
    expect(find.byKey(const Key('album-select')), findsOneWidget);
  });
}
