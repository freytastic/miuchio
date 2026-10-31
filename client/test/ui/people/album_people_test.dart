import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:miuchio/data/api/album_api.dart';
import 'package:miuchio/data/models/album_model.dart';
import 'package:miuchio/data/models/member_model.dart';
import 'package:miuchio/e2ee/identity.dart';
import 'package:miuchio/e2ee/identity_trust.dart';
import 'package:miuchio/ui/people/album_people.dart';
import 'package:miuchio/ui/people/security_codes_page.dart';
import 'package:miuchio/ui/providers/app_state.dart';

import 'trust_fakes.dart';

const _lake = '11111111-2222-3333-4444-555555555555';
const _city = '66666666-7777-8888-9999-aaaaaaaaaaaa';

Uint8List _ik(int b) => Uint8List.fromList(List.filled(32, b));

AlbumMember _member(String token, {Uint8List? ik, bool joined = true}) =>
    AlbumMember(
      memberToken: token,
      role: 'member',
      revoked: false,
      joinedAt: DateTime(2026),
      profile: MemberProfile(
        ikPub: ik == null ? null : base64.encode(ik),
        nameCt: joined ? 'ct-$token' : null,
      ),
    );

AlbumModel _album(String id) => AlbumModel(
      id: id,
      nameCt: null,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      memberToken: 'me',
    );

class _Albums extends AlbumService {
  final Map<String, List<AlbumMember>> members;
  _Albums(this.members);

  @override
  Future<List<AlbumMember>> listMembers(String albumId) async =>
      members[albumId] ?? const [];
}

void main() {
  late AppState state;
  late FakeTrust trust;
  late _Albums albums;

  setUp(() {
    state = AppState()
      ..setAlbums([_album(_lake), _album(_city)])
      ..setAlbumDisplayName(_lake, 'Lake')
      ..setAlbumDisplayName(_city, 'City');
    albums = _Albums({
      _lake: [
        _member('me', ik: _ik(9)),
        _member('ana', ik: _ik(1)),
        _member('bea', ik: _ik(2)),
        _member('cy', joined: false),
      ],
      _city: [
        _member('me', ik: _ik(9)),
        _member('ana-city', ik: _ik(1)),
      ],
    });
    // Ana is verified in Lake, but her code changed in City
    trust = FakeTrust({
      _lake: {'ana': TrustState.verified},
      _city: {'ana-city': TrustState.changed},
    });
  });

  Widget app(Widget Function(BuildContext) home) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: state),
          Provider<IdentityTrust>.value(value: trust),
          Provider<IdentityService>.value(value: FakeIdentity()),
        ],
        child: MaterialApp(home: Builder(builder: home)),
      );

  Future<void> openPeople(WidgetTester tester, String albumId) async {
    await tester.pumpWidget(app((context) => Scaffold(
          body: TextButton(
            onPressed: () =>
                openAlbumPeople(context, _album(albumId), service: albums),
            child: const Text('go'),
          ),
        )));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  Future<void> confirmMatch(WidgetTester tester) async {
    await tester.tap(find.text('They match'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('They matched'));
    await tester.pumpAndSettle();
  }

  testWidgets('lists only this album, without yourself or invites counted',
      (tester) async {
    await openPeople(tester, _lake);

    expect(find.byKey(const ValueKey('person-ana')), findsOneWidget);
    expect(find.byKey(const ValueKey('person-bea')), findsOneWidget);
    expect(find.byKey(const ValueKey('person-me')), findsNothing);
    expect(find.text("Hasn't joined yet"), findsOneWidget);
    expect(find.text('Lake · 1 of 2 verified'), findsOneWidget);
    expect(find.text('Verified'), findsOneWidget);
    expect(find.text('Not verified'), findsOneWidget);
    // Ana's change in City belongs to City alone
    expect(find.text('Security code changed'), findsNothing);
  });

  testWidgets('a changed code takes over the summary', (tester) async {
    await openPeople(tester, _city);

    expect(find.textContaining('security code changed'), findsOneWidget);
    expect(find.textContaining('verified'), findsNothing);
    expect(find.text('Security code changed'), findsOneWidget);
  });

  testWidgets('comparing uses this album from digits to verification',
      (tester) async {
    await openPeople(tester, _city);

    await tester.tap(find.byKey(const ValueKey('person-ana-city')));
    await tester.pumpAndSettle();
    expect(trust.numberedFor, [_city]);
    expect(find.text('Code for City'), findsOneWidget);
    expect(find.textContaining('open City'), findsOneWidget);

    await confirmMatch(tester);

    final v = trust.verified.single;
    expect(v.album, _city);
    expect(v.token, 'ana-city');
    expect(v.ik, _ik(1));
    // Lake is untouched, and City's list refreshed after the sheet closed
    expect(trust.states[_lake], {'ana': TrustState.verified});
    expect(find.text('City · 1 of 1 verified'), findsOneWidget);
    expect(find.text('Security code changed'), findsNothing);
  });

  testWidgets('a save that fails keeps the sheet open and says so',
      (tester) async {
    trust.failSaves = 1;
    await openPeople(tester, _lake);

    await tester.tap(find.byKey(const ValueKey('person-bea')));
    await tester.pumpAndSettle();
    await confirmMatch(tester);

    expect(find.byKey(const Key('safety-save-failed')), findsOneWidget);
    expect(find.text('Code for Lake'), findsOneWidget, reason: 'still open');

    await tester.tap(find.text('Try saving again'));
    await tester.pumpAndSettle();

    expect(trust.verified, hasLength(2));
    expect(find.text('Code for Lake'), findsNothing);
    expect(find.text('Lake · 2 of 2 verified'), findsOneWidget);
  });

  testWidgets('You lists only albums where a code changed', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(app((_) => SecurityCodesPage(
          service: albums,
          onOpenAlbum: (a) async => opened.add(a.id),
        )));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('check-$_city')), findsOneWidget);
    expect(find.byKey(const ValueKey('check-$_lake')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('check-$_city')));
    await tester.pumpAndSettle();
    expect(opened, [_city]);
  });

  testWidgets('You says plainly when no code has changed', (tester) async {
    trust.states[_city] = {'ana-city': TrustState.verified};
    await tester.pumpWidget(app((_) => SecurityCodesPage(
          service: albums,
          onOpenAlbum: (_) async {},
        )));
    await tester.pumpAndSettle();

    expect(find.text('No security codes have changed.'), findsOneWidget);
  });
}
