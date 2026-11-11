import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/e2ee/album_authority.dart';
import 'package:miuchio/e2ee/authority_records.dart';
import 'package:miuchio/e2ee/identity.dart';

import '../_sodium_setup.dart';
import '_admin_test_helpers.dart';
import '_authority_test_helpers.dart';

final _album = Uint8List.fromList(List.generate(16, (i) => 0x40 + i));
Uint8List _token(int b) => Uint8List.fromList(List.filled(32, b));
final _alice = _token(0xA1);
final _bob = _token(0xB2);
final _carol = _token(0xC3);

String _hex(Uint8List b) => AlbumAuthority.tokenHex(b);

void main() {
  setUpAll(ensureSodium);

  late IdentityService alice;
  late IdentityService bob;
  late IdentityService carol;
  late IdentityService mallory;
  late FakeAuthorityApi api;
  late AlbumAuthority authority;

  setUp(() async {
    alice = (await newResponderIdentity()).svc;
    bob = (await newResponderIdentity()).svc;
    carol = (await newResponderIdentity()).svc;
    mallory = (await newResponderIdentity()).svc;
    api = FakeAuthorityApi();
    authority = memoryAuthority(api).authority;
  });

  Future<void> anchorAlice() async => authority.anchorCreator(
        albumId: _album,
        selfToken: _alice,
        ikPub: await alice.currentIkPub(),
        lkPub: await alice.currentLkPub(),
      );

  Future<SignedHandover> aliceToBob() => nextHandover(alice,
      albumId: _album,
      chain: api.handovers,
      oldToken: _alice,
      newToken: _bob,
      newAdmin: bob);

  group('verifiedRoster', () {
    test('keeps notes the trusted admin signed and flags the rest', () async {
      await anchorAlice();
      api.notes = [
        await noteFor(alice,
            albumId: _album, memberToken: _alice, member: alice),
        await noteFor(alice, albumId: _album, memberToken: _bob, member: bob),
        // Signed by someone the device has no reason to trust
        await noteFor(mallory,
            albumId: _album, memberToken: _carol, member: mallory),
      ];

      final roster = await authority.verifiedRoster(_album);

      expect(roster.term, 0);
      expect(roster.members.keys, {_hex(_alice), _hex(_bob)});
      expect(roster.members[_hex(_bob)]!.ikPub, await bob.currentIkPub());
      expect(roster.unverified, {_hex(_carol)});
    });

    test('a member whose verified notes disagree on keys is unverified',
        () async {
      await anchorAlice();
      api.handovers = [await aliceToBob()];
      api.adminTerm = 1;
      api.notes = [
        await noteFor(alice,
            albumId: _album, memberToken: _carol, member: carol),
        // The next admin vouches for other keys under the same membership
        await noteFor(bob,
            albumId: _album,
            memberToken: _carol,
            member: mallory,
            issuerTerm: 1),
      ];

      final roster = await authority.verifiedRoster(_album);

      expect(roster.term, 1);
      expect(roster.members, isEmpty);
      expect(roster.unverified, {_hex(_carol)});
    });

    test('refuses an album with no anchor', () async {
      expect(() => authority.verifiedRoster(_album),
          throwsA(isA<AuthorityChainException>()));
    });
  });

  group('sync', () {
    test('follows a handover and trusts notes from the new admin', () async {
      await anchorAlice();
      api.handovers = [await aliceToBob()];

      final chain = await authority.sync(_album);

      expect(chain!.latestTerm, 1);
      expect(chain.currentAdmin.token, _bob);
      expect(authority.chain(_album)!.latestTerm, 1, reason: 'saved');
      final keys = await authority.verifySender(_album, _carol, 1, [
        await noteFor(bob,
            albumId: _album, memberToken: _carol, member: carol, issuerTerm: 1),
      ]);
      expect(keys!.ikPub, await carol.currentIkPub());
    });

    test('a handover the admin before did not sign is refused', () async {
      await anchorAlice();
      api.handovers = [
        await nextHandover(mallory,
            albumId: _album,
            chain: const [],
            oldToken: _alice,
            newToken: _carol,
            newAdmin: mallory),
      ];

      await expectLater(
          authority.sync(_album), throwsA(isA<AuthorityChainException>()));
      expect(authority.chain(_album)!.latestTerm, 0);
    });

    test('a record that does not chain from the one before is refused',
        () async {
      await anchorAlice();
      final first = await aliceToBob();
      final second = await signHandover(
        bob,
        AdminHandover(
          albumId: _album,
          term: 2,
          prevHash: Uint8List(32),
          oldToken: _bob,
          newToken: _carol,
          newGeneration: 1,
          newIkPub: await carol.currentIkPub(),
          newLkPub: await carol.currentLkPub(),
          mode: kHandoverStay,
          deleteMedia: false,
        ),
      );
      api.handovers = [first, second];

      await expectLater(
          authority.sync(_album), throwsA(isA<AuthorityChainException>()));
      expect(authority.chain(_album)!.latestTerm, 0);
    });

    test('a record this device already trusts cannot be swapped', () async {
      await anchorAlice();
      api.handovers = [await aliceToBob()];
      await authority.sync(_album);

      // Alice really signed this too, but it is not the record seen before
      api.handovers = [
        await nextHandover(alice,
            albumId: _album,
            chain: const [],
            oldToken: _alice,
            newToken: _carol,
            newAdmin: carol),
      ];

      await expectLater(
          authority.head(_album), throwsA(isA<AuthorityChainException>()));
      expect(authority.chain(_album)!.currentAdmin.token, _bob);
    });

    test('a hidden handover cannot be skipped', () async {
      await anchorAlice();
      final first = await aliceToBob();
      api.handovers = [first];
      final second = await nextHandover(bob,
          albumId: _album,
          chain: api.handovers,
          oldToken: _bob,
          newToken: _carol,
          newAdmin: carol);
      api.handovers = [second];

      await expectLater(
          authority.sync(_album), throwsA(isA<AuthorityChainException>()));
    });
  });

  group('anchors', () {
    test('a device anchored later never trusts an earlier term', () async {
      api.handovers = [await aliceToBob()];
      // Bob invited this device at term 1
      await authority.adoptAnchor(
          _album,
          await noteFor(bob,
              albumId: _album, memberToken: _bob, member: bob, issuerTerm: 1));

      await authority.sync(_album);

      final keys = await authority.verifySender(_album, _carol, 1, [
        await noteFor(alice,
            albumId: _album, memberToken: _carol, member: carol),
      ]);
      expect(keys, isNull);
      expect(authority.chain(_album)!.admins.keys, {1});
    });

    test('adoptAnchor never replaces one already held', () async {
      await anchorAlice();
      await authority.adoptAnchor(
          _album,
          await noteFor(mallory,
              albumId: _album, memberToken: _carol, member: mallory));
      expect(authority.chain(_album)!.currentAdmin.token, _alice);
    });

    // Alice invites this device (Carol) at term 0, hands to Bob, Bob hands
    // back. Alice inviting again at term 2 reissues Carol's note there too
    test('a first join anchors on the term it was invited under', () async {
      final carolToken = _token(0xC3);
      final aliceSelf0 = await noteFor(alice,
          albumId: _album, memberToken: _alice, member: alice);
      final aliceSelf2 = await noteFor(alice,
          albumId: _album, memberToken: _alice, member: alice, issuerTerm: 2);
      api.notes = [
        await noteFor(alice,
            albumId: _album, memberToken: carolToken, member: carol),
        await noteFor(alice,
            albumId: _album,
            memberToken: carolToken,
            member: carol,
            issuerTerm: 2),
      ];

      final picked = await authority.invitationNote(
          _album, [aliceSelf2, aliceSelf0], _alice, 1,
          selfIk: await carol.currentIkPub());
      expect(picked!.note.issuerTerm, 0);

      await authority.adoptAnchor(_album, picked);
      final toBob = await aliceToBob();
      api.handovers = [
        toBob,
      ];
      api.handovers = [
        toBob,
        await nextHandover(bob,
            albumId: _album,
            chain: api.handovers,
            oldToken: _bob,
            newToken: _alice,
            newAdmin: alice),
      ];
      // Bob left when he handed back, so his rotation only carries the note
      // Alice issued him at term 0
      final keys = await authority.verifySender(_album, _bob, 1, [
        await noteFor(alice, albumId: _album, memberToken: _bob, member: bob),
      ]);
      expect(keys!.ikPub, await bob.currentIkPub());
    });

    test('no invitation note for this device names nobody', () async {
      final aliceSelf = await noteFor(alice,
          albumId: _album, memberToken: _alice, member: alice);
      // Vouches for Carol's key, but signed by someone else
      api.notes = [
        await noteFor(mallory,
            albumId: _album, memberToken: _carol, member: carol),
      ];
      expect(
          await authority.invitationNote(_album, [aliceSelf], _alice, 1,
              selfIk: await carol.currentIkPub()),
          isNull);
    });

    test('an inviter note that is not self signed is ignored', () async {
      final forged = SignedNote(
        MemberNote(
          albumId: _album,
          memberToken: _alice,
          generation: 1,
          ikPub: await alice.currentIkPub(),
          lkPub: await alice.currentLkPub(),
          issuerTerm: 0,
        ),
        Uint8List(64),
      );
      api.notes = [
        await noteFor(alice,
            albumId: _album, memberToken: _carol, member: carol),
      ];
      expect(
          await authority.invitationNote(_album, [forged], _alice, 1,
              selfIk: await carol.currentIkPub()),
          isNull);
    });
  });

  test('verifySender fetches handovers only for a term it does not know',
      () async {
    await anchorAlice();
    final note =
        await noteFor(alice, albumId: _album, memberToken: _bob, member: bob);

    expect(await authority.verifySender(_album, _bob, 1, [note]), isNotNull);
    expect(api.handoverFetches, 0);
    expect(await authority.verifySender(_album, _bob, 2, [note]), isNull,
        reason: 'a note for an earlier membership does not carry over');
  });
}
