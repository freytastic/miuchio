import 'dart:async';
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
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/data/models/member_model.dart';
import 'package:miuchio/data/storage/name_cache.dart';
import 'package:miuchio/e2ee/album_keys.dart';
import 'package:miuchio/e2ee/member_removal.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/album/album_copy.dart';
import 'package:miuchio/ui/album/member_avatars.dart';
import 'package:miuchio/ui/people/people_screen.dart';
import 'package:miuchio/ui/screens/album_detail_screen.dart';
import 'package:miuchio/ui/shelf/shelf_data.dart';
import 'package:miuchio/ui/widgets/member_face.dart';

import '../secure_store/mock_secure_key_store.dart';

import 'package:miuchio/ui/providers/upload_queue_model.dart';
import 'upload_scaffold.dart';

class _MockAlbumService extends AlbumService {
  final List<AlbumMember> members;
  _MockAlbumService(this.members);

  @override
  Future<List<AlbumMember>> listMembers(String albumId) async => members;
}

// _StubMediaApi : returns the in memory items list : never makes a real HTTP
// call. Tests construct this with whatever rows they want the screen to render
class _StubMediaApi extends MediaApi {
  final List<MediaRecord> items;
  _StubMediaApi(this.items) : super(ApiClient());

  @override
  Future<List<MediaRecord>> listMedia(String _) async => items;

  @override
  void dispose() {}
}

Future<AlbumKeyStore> _emptyAks() async {
  final s = MockSecureKeyStore();
  await s.initialize();
  final aks = AlbumKeyStore(s);
  await aks.initialize();
  return aks;
}

AlbumModel _fakeAlbum({String? me}) => AlbumModel(
      id: 'album-1',
      nameCt: null,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      memberToken: me,
    );

AlbumMember _fakeMember(String token, String role) => AlbumMember(
      memberToken: token,
      role: role,
      revoked: false,
      joinedAt: DateTime(2024),
      profile: MemberProfile(),
    );

Never _unused() => throw UnimplementedError();

// The person sheet reads it before any action is picked
final _idleRemoval = MemberRemovalCoordinator(
  revoke: (_, __, {deleteMedia = false}) async => _unused(),
  activeTokens: (_) async => _unused(),
  currentEpoch: (_) async => _unused(),
  rotate: (_, __, ___) async => _unused(),
  expectedIk: (_, __) async => _unused(),
  dropDirectory: (_, __) => _unused(),
  wipeLocalAlbum: (_) async => _unused(),
  isRotationRequired: (_) async => _unused(),
);

Widget _wrap(Widget child, AlbumKeyStore aks, {NameCache? names}) =>
    MultiProvider(
      providers: [
        if (names != null) Provider<NameCache>.value(value: names),
        Provider<MemberRemovalCoordinator>.value(value: _idleRemoval),
        ChangeNotifierProvider(create: (_) => AppState()),
        Provider<AlbumKeyStore>.value(value: aks),
        ChangeNotifierProvider<UploadQueueModel>.value(
            value: idleUploadQueue()),
      ],
      child: MaterialApp(home: child),
    );

void main() {
  // Without a published name, a peer has not opened the album yet
  testWidgets('AlbumDetailScreen shows members as avatars, never as tokens',
      (tester) async {
    final aks = await _emptyAks();
    await tester.pumpWidget(_wrap(
      AlbumDetailScreen(
        album: _fakeAlbum(me: 'alicetoken123'),
        albumService: _MockAlbumService([
          _fakeMember('alicetoken123', 'admin'),
          _fakeMember('bobtoken456', 'member'),
        ]),
        mediaApi: _StubMediaApi(const []),
      ),
      aks,
    ));
    await tester.pumpAndSettle();

    expect(find.text('alicetok'), findsNothing);
    expect(find.text('bobtoken'), findsNothing);
    expect(find.byType(MemberAvatars), findsOneWidget);
    expect(find.text('·'), findsOneWidget);
    // Bob's place while he has not opened it, and the owner's add slot
    expect(find.byType(DashedCircle), findsNWidgets(2));
    expect(
        find.descendant(
            of: find.byType(AddSlot), matching: find.byType(DashedCircle)),
        findsOneWidget);
  });

  testWidgets('an invited member is counted as invited, not as a person',
      (tester) async {
    final aks = await _emptyAks();
    await tester.pumpWidget(_wrap(
      AlbumDetailScreen(
        album: _fakeAlbum(me: 'alicetoken123'),
        albumService: _MockAlbumService([
          _fakeMember('alicetoken123', 'admin'),
          _fakeMember('bobtoken456', 'member'),
        ]),
        mediaApi: _StubMediaApi(const []),
      ),
      aks,
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('1 person, 1 invited'), findsOneWidget);
  });

  for (final (me, admin) in [('alicetoken123', true), ('bobtoken456', false)]) {
    testWidgets('add someone is offered only to the admin ($me)',
        (tester) async {
      final aks = await _emptyAks();
      await tester.pumpWidget(_wrap(
        AlbumDetailScreen(
          album: _fakeAlbum(me: me),
          albumService: _MockAlbumService([
            _fakeMember('alicetoken123', 'admin'),
            _fakeMember('bobtoken456', 'member'),
          ]),
          mediaApi: _StubMediaApi(const []),
        ),
        aks,
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('add-someone')),
          admin ? findsOneWidget : findsNothing);
    });
  }

  testWidgets('people opens the album roster without our own row',
      (tester) async {
    final aks = await _emptyAks();
    await tester.pumpWidget(_wrap(
      AlbumDetailScreen(
        album: _fakeAlbum(me: 'alicetoken123'),
        albumService: _MockAlbumService([
          _fakeMember('alicetoken123', 'admin'),
          _fakeMember('bobtoken456', 'member'),
        ]),
        mediaApi: _StubMediaApi(const []),
      ),
      aks,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip(AlbumCopy.settings).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('album-settings-people')));
    await tester.pumpAndSettle();

    expect(find.byType(PeopleScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('person-bobtoken456')), findsOneWidget);
    expect(find.byKey(const ValueKey('person-alicetoken123')), findsNothing);
  });

  testWidgets(
      'AlbumDetailScreen exits itself when the album is removed '
      '(kicked while viewing)', (tester) async {
    final aks = await _emptyAks();
    final appState = AppState();
    appState.setAlbums([_fakeAlbum()]);

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appState),
        Provider<AlbumKeyStore>.value(value: aks),
        ChangeNotifierProvider<UploadQueueModel>.value(
            value: idleUploadQueue()),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                  builder: (_) => AlbumDetailScreen(
                    album: _fakeAlbum(),
                    albumService: _MockAlbumService(
                        [_fakeMember('mytoken12345', 'member')]),
                    mediaApi: _StubMediaApi(const []),
                  ),
                )),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(AlbumDetailScreen), findsOneWidget);

    // the admin kicks this user -> onSelfRemoved drops the album from state
    appState.removeAlbum('album-1');
    await tester.pumpAndSettle();

    // the detail screen closed itself; we're back on the launcher
    expect(find.byType(AlbumDetailScreen), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets(
      'AlbumDetailScreen does NOT auto-exit after re-invite '
      '(stale removal signal cleared on rejoin)', (tester) async {
    final aks = await _emptyAks();
    final appState = AppState();
    appState.setAlbums([_fakeAlbum()]);
    // kicked earlier: removal signal is set for album-1
    appState.removeAlbum('album-1');
    // re invited + rejoined: album-1 comes back, which must clear the signal
    appState.prependAlbum(_fakeAlbum());
    expect(appState.lastRemovedAlbumId, isNull);

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appState),
        Provider<AlbumKeyStore>.value(value: aks),
        ChangeNotifierProvider<UploadQueueModel>.value(
            value: idleUploadQueue()),
      ],
      child: MaterialApp(
        home: AlbumDetailScreen(
          album: _fakeAlbum(),
          albumService:
              _MockAlbumService([_fakeMember('mytoken12345', 'member')]),
          mediaApi: _StubMediaApi(const []),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // the screen stayed open (was not bounced by the stale kicked while viewing
    // guard)
    expect(find.byType(AlbumDetailScreen), findsOneWidget);
  });

  testWidgets('a successful realtime reload advances the seen watermark',
      (tester) async {
    final aks = await _emptyAks();
    final album = _fakeAlbum().copyWith(
      mediaCount: 4,
      mediaGeneration: 4,
      hasSummary: true,
    );
    final appState = AppState()..setAlbums([album]);
    final seen = InMemorySeenStore();

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appState),
        Provider<AlbumKeyStore>.value(value: aks),
        ChangeNotifierProvider<UploadQueueModel>.value(
            value: idleUploadQueue()),
        ListenableProvider<SeenStore>.value(value: seen),
      ],
      child: MaterialApp(
        home: AlbumDetailScreen(
          album: album,
          albumService: _MockAlbumService([]),
          mediaApi: _StubMediaApi(const []),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(seen.lastSeen(album.id), 4);

    appState.applyMediaAdded(album.id, 5);
    appState.notifyMediaAdded(album.id, 'media-5');
    await tester.pumpAndSettle();

    expect(seen.lastSeen(album.id), 5);
  });

  Future<NameCache> names(WidgetTester tester) async =>
      (await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('miuchio_names');
        addTearDown(() => dir.delete(recursive: true));
        return NameCache.open(
            file: File('${dir.path}/n.kec'), cacheRootKey: Uint8List(32));
      }))!;

  // A joined member: a published name, even one this phone can't open yet
  AlbumMember joined(String token, String role) => AlbumMember(
        memberToken: token,
        role: role,
        revoked: false,
        joinedAt: DateTime(2024),
        profile: MemberProfile(nameCt: 'sealed'),
        joined: true,
      );

  for (final (me, admin) in [('alicetoken123', true), ('bobtoken456', false)]) {
    testWidgets('a person sheet offers removal only to the creator ($me)',
        (tester) async {
      final aks = await _emptyAks();
      await tester.pumpWidget(_wrap(
        AlbumDetailScreen(
          album: _fakeAlbum(me: me),
          albumService: _MockAlbumService([
            joined('alicetoken123', 'admin'),
            joined('bobtoken456', 'member'),
            joined('caroltoken789', 'member'),
          ]),
          mediaApi: _StubMediaApi(const []),
        ),
        aks,
        names: await names(tester),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(AlbumCopy.settings).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('album-settings-people')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('person-caroltoken789')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('person-photos')), findsOneWidget);
      expect(find.byKey(const Key('person-safety')), findsOneWidget);
      expect(find.byKey(const Key('person-remove')),
          admin ? findsOneWidget : findsNothing);
      expect(find.byKey(const Key('person-make-owner')),
          admin ? findsOneWidget : findsNothing);
    });
  }

  testWidgets('only someone who opened the album can be made owner',
      (tester) async {
    // Tall enough for the whole settings page
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final aks = await _emptyAks();
    await tester.pumpWidget(_wrap(
      AlbumDetailScreen(
        album: _fakeAlbum(me: 'alicetoken123'),
        albumService: _MockAlbumService([
          joined('alicetoken123', 'admin'),
          AlbumMember(
            memberToken: 'bobtoken456',
            role: 'member',
            revoked: false,
            joinedAt: DateTime(2024),
            profile: MemberProfile(nameCt: 'sealed'),
          ),
        ]),
        mediaApi: _StubMediaApi(const []),
      ),
      aks,
      names: await names(tester),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(AlbumCopy.settings).first);
    await tester.pumpAndSettle();

    // Nobody can take over yet, so the owner can only delete
    expect(find.text(AlbumCopy.leaveAlbum), findsNothing);
    expect(find.text(AlbumCopy.deleteAlbum), findsOneWidget);

    await tester.tap(find.byKey(const Key('album-settings-people')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('person-bobtoken456')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('person-remove')), findsOneWidget);
    expect(find.byKey(const Key('person-make-owner')), findsNothing);
  });

  testWidgets('an owner with someone to take over can also leave',
      (tester) async {
    // Tall enough for the whole settings page
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final aks = await _emptyAks();
    await tester.pumpWidget(_wrap(
      AlbumDetailScreen(
        album: _fakeAlbum(me: 'alicetoken123'),
        albumService: _MockAlbumService([
          joined('alicetoken123', 'admin'),
          joined('bobtoken456', 'member'),
        ]),
        mediaApi: _StubMediaApi(const []),
      ),
      aks,
      names: await names(tester),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(AlbumCopy.settings).first);
    await tester.pumpAndSettle();

    expect(find.text(AlbumCopy.leaveAlbum), findsOneWidget);
    expect(find.text(AlbumCopy.deleteAlbum), findsOneWidget);

    // Deleting offers handing the album on first
    await tester.tap(find.text(AlbumCopy.deleteAlbum));
    await tester.pumpAndSettle();
    expect(find.text(AlbumCopy.deleteOrHandOverTitle), findsOneWidget);
    expect(find.text(AlbumCopy.deleteForEveryone), findsOneWidget);

    // and the people who could take over show with their faces
    await tester.tap(find.text(AlbumCopy.handOverAndLeave));
    await tester.pumpAndSettle();
    expect(find.text(AlbumCopy.newOwnerTitle), findsOneWidget);
    expect(
        find.descendant(
            of: find
                .ancestor(
                    of: find.text(AlbumCopy.newOwnerTitle),
                    matching: find.byType(Column))
                .first,
            matching: find.byType(MemberFace)),
        findsOneWidget);
  });

  testWidgets("their photos goes back to the album filtered to them",
      (tester) async {
    final aks = await _emptyAks();
    await tester.pumpWidget(_wrap(
      AlbumDetailScreen(
        album: _fakeAlbum(me: 'alicetoken123'),
        albumService: _MockAlbumService([
          joined('alicetoken123', 'admin'),
          joined('bobtoken456', 'member'),
        ]),
        mediaApi: _StubMediaApi(const []),
      ),
      aks,
      names: await names(tester),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(AlbumCopy.settings).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('album-settings-people')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('person-bobtoken456')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('person-photos')));
    await tester.pumpAndSettle();

    expect(find.byType(PeopleScreen), findsNothing);
    expect(find.text(AlbumCopy.filteredBy(null, 0)), findsOneWidget);
  });

  // A back gesture during a slow leave, then
  // the leave finishing, left the app with no screen at all
  testWidgets('a back gesture during a slow leave keeps the shelf',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final aks = await _emptyAks();
    final wipe = Completer<void>();
    // Leaving decodes the token, so it has to be real base64
    final bob = base64.encode(List<int>.filled(32, 0xB0));
    final removal = MemberRemovalCoordinator(
      revoke: (_, __, {deleteMedia = false}) async => true,
      activeTokens: (_) async => _unused(),
      currentEpoch: (_) async => _unused(),
      rotate: (_, __, ___) async => _unused(),
      expectedIk: (_, __) async => _unused(),
      dropDirectory: (_, __) {},
      wipeLocalAlbum: (_) => wipe.future,
      isRotationRequired: (_) async => false,
    );
    final album = AlbumModel(
      id: '1574e8d1-0000-4000-8000-000000000001',
      nameCt: null,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      memberToken: bob,
    );
    final screen = AlbumDetailScreen(
      album: album,
      albumService: _MockAlbumService([
        joined('alicetoken123', 'admin'),
        joined(bob, 'member'),
      ]),
      mediaApi: _StubMediaApi(const []),
    );
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<NameCache>.value(value: await names(tester)),
        Provider<MemberRemovalCoordinator>.value(value: removal),
        ChangeNotifierProvider(create: (_) => AppState()),
        Provider<AlbumKeyStore>.value(value: aks),
        ChangeNotifierProvider<UploadQueueModel>.value(
            value: idleUploadQueue()),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute<void>(builder: (_) => screen)),
              child: const Text('shelf'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('shelf'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(AlbumCopy.settings).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(AlbumCopy.leaveAlbum));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('album-leave-confirm')));
    await tester.pump();

    // Back while the wipe is still running, then the wipe ends mid animation
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump(const Duration(milliseconds: 100));
    expect(wipe.isCompleted, isFalse);
    wipe.complete();
    await tester.pumpAndSettle();

    expect(find.text('shelf'), findsOneWidget);
  });
}
