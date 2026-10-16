import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:miuchio/crypto/uuid_bytes.dart';
import 'package:miuchio/data/api/album_api.dart';
import 'package:miuchio/data/api/api_client.dart';
import 'package:miuchio/data/api/media_api.dart';
import 'package:miuchio/data/models/album_model.dart';
import 'package:miuchio/data/models/member_model.dart';
import 'package:miuchio/e2ee/album_keys.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/e2ee/sealed_name.dart';
import 'package:miuchio/ui/album/album_copy.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/screens/album_detail_screen.dart';

import '../_sodium_setup.dart';
import '../secure_store/mock_secure_key_store.dart';

import 'package:miuchio/ui/providers/upload_queue_model.dart';
import 'upload_scaffold.dart';

const _albumId = '0f8fad5b-d9cb-469f-a165-70867728950e';

class _RecordingAlbumService extends AlbumService {
  final renamed = <String>[];

  @override
  Future<List<AlbumMember>> listMembers(String albumId) async => [
        _member('alice', 'admin'),
        _member('bob', 'member'),
      ];

  @override
  Future<bool> updateAlbumNameCt(String albumId, String nameCtB64) async {
    renamed.add(nameCtB64);
    return true;
  }
}

class _StubMediaApi extends MediaApi {
  _StubMediaApi() : super(ApiClient());

  @override
  Future<List<MediaRecord>> listMedia(String _) async => const [];

  @override
  void dispose() {}
}

AlbumMember _member(String token, String role) => AlbumMember(
      memberToken: token,
      role: role,
      revoked: false,
      joinedAt: DateTime(2024),
      profile: MemberProfile(),
    );

void main() {
  setUpAll(ensureSodium);

  late AlbumKeyStore aks;
  late AppState app;
  late _RecordingAlbumService albums;

  setUp(() async {
    final store = MockSecureKeyStore();
    await store.initialize();
    aks = AlbumKeyStore(store);
    await aks.initialize();
    await aks.install(uuidToBytes(_albumId)!, 0, Uint8List(32));
    app = AppState()..setAlbumDisplayName(_albumId, 'Trip');
    albums = _RecordingAlbumService();
  });

  Widget wrap(String me) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: app),
          Provider<AlbumKeyStore>.value(value: aks),
          ChangeNotifierProvider<UploadQueueModel>.value(
              value: idleUploadQueue()),
        ],
        child: MaterialApp(
          home: AlbumDetailScreen(
            album: AlbumModel(
              id: _albumId,
              nameCt: null,
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
              memberToken: me,
            ),
            albumService: albums,
            mediaApi: _StubMediaApi(),
          ),
        ),
      );

  testWidgets('the creator renames by tapping the title', (tester) async {
    await tester.pumpWidget(wrap('alice'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('album-title')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('rename-save')));
    await tester.pumpAndSettle();
    expect(albums.renamed, isEmpty, reason: 'an unchanged name is not saved');

    await tester.enterText(find.byType(TextField), '  Beach  ');
    await tester.pump();
    await tester.tap(find.byKey(const Key('rename-save')));
    await tester.runAsync(() async {
      for (var i = 0; i < 20 && albums.renamed.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();

    expect(albums.renamed, hasLength(1));
    final opened = await tester.runAsync(() => SealedName.openAlbumName(
        aks, uuidToBytes(_albumId)!, albums.renamed.single));
    expect(opened, 'Beach', reason: 'sealed under the album key, trimmed');
    expect(app.albumDisplayName(_albumId), 'Beach');
    expect(find.text('Beach'), findsWidgets);
  });

  testWidgets('a member who did not make the album cannot rename it',
      (tester) async {
    await tester.pumpWidget(wrap('bob'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('album-title')), findsNothing);
    await tester.tap(find.byTooltip(AlbumCopy.more).first);
    await tester.pumpAndSettle();
    expect(find.text(AlbumCopy.renameAlbum), findsNothing);
  });
}
