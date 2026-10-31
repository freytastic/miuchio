import 'dart:convert';
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
import 'package:miuchio/data/storage/name_cache.dart';
import 'package:miuchio/e2ee/album_keys.dart';
import 'package:miuchio/e2ee/identity.dart';
import 'package:miuchio/e2ee/identity_trust.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/providers/upload_queue_model.dart';
import 'package:miuchio/ui/screens/album_detail_screen.dart';

import '../secure_store/mock_secure_key_store.dart';
import 'people/trust_fakes.dart';
import 'upload_scaffold.dart';

const _id = '11111111-2222-3333-4444-555555555555';

Uint8List _ik(int b) => Uint8List.fromList(List.filled(32, b));

AlbumMember _member(String token, {Uint8List? ik, bool joined = true}) =>
    AlbumMember(
      memberToken: token,
      role: token == 'me' ? 'admin' : 'member',
      revoked: false,
      joinedAt: DateTime(2026),
      profile: MemberProfile(
        ikPub: ik == null ? null : base64.encode(ik),
        nameCt: joined ? 'sealed' : null,
      ),
    );

class _Albums extends AlbumService {
  @override
  Future<List<AlbumMember>> listMembers(String albumId) async => [
        _member('me', ik: _ik(9)),
        _member('ana', ik: _ik(1)),
        _member('bea', ik: _ik(2)),
        _member('cy', joined: false),
      ];
}

class _NoMedia extends MediaApi {
  _NoMedia() : super(ApiClient());
  @override
  Future<List<MediaRecord>> listMedia(String _) async => const [];
  @override
  void dispose() {}
}

void main() {
  late FakeTrust trust;

  setUp(() => trust = FakeTrust({
        _id: {'ana': TrustState.verified},
      }));

  Future<void> pump(WidgetTester tester) async {
    final ks = MockSecureKeyStore();
    await ks.initialize();
    final aks = AlbumKeyStore(ks);
    await aks.initialize();
    final names = (await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('miuchio_names');
      addTearDown(() => dir.delete(recursive: true));
      return NameCache.open(
          file: File('${dir.path}/n.kec'), cacheRootKey: Uint8List(32));
    }))!;
    final album = AlbumModel(
      id: _id,
      nameCt: null,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      memberToken: 'me',
    );
    final state = AppState()
      ..setAlbums([album])
      ..setAlbumDisplayName(_id, 'Lake');
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: state),
        Provider<AlbumKeyStore>.value(value: aks),
        Provider<NameCache>.value(value: names),
        Provider<IdentityTrust>.value(value: trust),
        Provider<IdentityService>.value(value: FakeIdentity()),
        ChangeNotifierProvider<UploadQueueModel>.value(
            value: idleUploadQueue()),
      ],
      child: MaterialApp(
        home: AlbumDetailScreen(
            album: album, albumService: _Albums(), mediaApi: _NoMedia()),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the header counts joined people, never you or an invite',
      (tester) async {
    await pump(tester);

    expect(find.text('1 of 2 verified'), findsOneWidget);
  });

  testWidgets('a changed code in this album replaces the count',
      (tester) async {
    trust.states[_id]!['bea'] = TrustState.changed;
    await pump(tester);

    expect(find.textContaining('security code changed'), findsWidgets);
    expect(find.text('1 of 2 verified'), findsNothing);
  });

  testWidgets('verifying from the album refreshes its header', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const Key('album-security')));
    await tester.pumpAndSettle();
    expect(find.text('Lake · 1 of 2 verified'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('person-bea')));
    await tester.pumpAndSettle();
    expect(find.text('Code for Lake'), findsOneWidget);
    await tester.tap(find.text('They match'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('They matched'));
    await tester.pumpAndSettle();
    expect(trust.verified.single.album, _id);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.text('2 of 2 verified'), findsOneWidget);
  });
}
