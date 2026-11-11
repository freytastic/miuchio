import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/e2ee/album_authority.dart';
import 'package:miuchio/e2ee/album_keys.dart';
import 'package:miuchio/e2ee/authority_records.dart';
import 'package:miuchio/e2ee/epoch_processor.dart';
import 'package:miuchio/e2ee/identity.dart';
import 'package:miuchio/e2ee/member_directory.dart';
import 'package:miuchio/e2ee/sender_resolver.dart';
import 'package:miuchio/e2ee/wrap_envelope.dart';

import '../_sodium_setup.dart';
import '_admin_test_helpers.dart';
import '_authority_test_helpers.dart';

final _album = Uint8List.fromList(List.generate(16, (i) => 0x20 + i));
Uint8List _token(int b) => Uint8List.fromList(List.filled(32, b));
final _self = _token(0x5E);

WrapEnvelope _from(Uint8List sender, List<SignedNote> notes,
        {int generation = 1}) =>
    WrapEnvelope(
      epoch: 0,
      ekPub: Uint8List(32),
      wrap: Uint8List(61),
      senderToken: sender,
      senderSig: Uint8List(64),
      opkIdxUsed: null,
      deliveredAt: DateTime.utc(2026, 11, 11),
      senderGeneration: generation,
      senderNotes: [for (final n in notes) n.toJson()],
    );

void main() {
  setUpAll(ensureSodium);

  late IdentityService me;
  late SyntheticAdmin admin;
  late IdentityService mallory;
  late AlbumAuthority authority;
  late AuthoritySenders senders;

  setUp(() async {
    me = (await newResponderIdentity()).svc;
    admin = await SyntheticAdmin.create();
    mallory = (await newResponderIdentity()).svc;
    // The note the inviter signed for this device when inviting it
    final api = FakeAuthorityApi()
      ..notes = [
        await noteFor(admin.identity,
            albumId: _album, memberToken: _self, member: me),
      ];
    authority = memoryAuthority(api).authority;
    senders = AuthoritySenders(
      authority: authority,
      identity: me,
      selfToken: (_) => _self,
    );
  });

  Future<SignedNote> adminSelfNote() => noteFor(admin.identity,
      albumId: _album, memberToken: admin.senderToken, member: admin.identity);

  test('this device is its own sender', () async {
    final got =
        await senders.resolve(_album, _from(_self, const []), allowTofu: false);
    expect(got!.vouched, isTrue);
    expect(got.pubs.ikPub, await me.currentIkPub());
  });

  test('a first join takes the inviter on their own note, adopted later',
      () async {
    final got = await senders.resolve(
        _album, _from(admin.senderToken, [await adminSelfNote()]),
        allowTofu: true);

    expect(got!.vouched, isFalse);
    expect(got.pubs.ikPub, admin.ikPub);
    expect(authority.hasAnchor(_album), isFalse,
        reason: 'nothing is trusted before the wrap verifies');
    await got.adopt!();
    expect(authority.chain(_album)!.currentAdmin.token, admin.senderToken);
  });

  test('a device holding keys never takes a signer on trust', () async {
    await expectLater(
      senders.resolve(_album, _from(admin.senderToken, [await adminSelfNote()]),
          allowTofu: false),
      throwsA(isA<UnknownSignerException>()),
    );
  });

  test('a first join with no note names nobody', () async {
    expect(
        await senders.resolve(_album, _from(admin.senderToken, const []),
            allowTofu: true),
        isNull);
  });

  group('anchored', () {
    setUp(() async => authority.adoptAnchor(_album, await adminSelfNote()));

    test('a member the admin vouched for is verified under that note',
        () async {
      final member = _token(0x77);
      final note = await noteFor(admin.identity,
          albumId: _album, memberToken: member, member: mallory);
      final got = await senders.resolve(_album, _from(member, [note]),
          allowTofu: false);
      expect(got!.vouched, isTrue);
      expect(got.pubs.ikPub, await mallory.currentIkPub());
      expect(got.adopt, isNull);
    });

    test('a note the trusted admin did not sign is refused', () async {
      final member = _token(0x77);
      final forged = await noteFor(mallory,
          albumId: _album, memberToken: member, member: mallory);
      await expectLater(
        senders.resolve(_album, _from(member, [forged]), allowTofu: true),
        throwsA(isA<UnknownSignerException>()),
      );
    });

    test('a note for an earlier membership does not vouch for a rejoin',
        () async {
      final member = _token(0x77);
      final note = await noteFor(admin.identity,
          albumId: _album, memberToken: member, member: mallory);
      await expectLater(
        senders.resolve(_album, _from(member, [note], generation: 2),
            allowTofu: false),
        throwsA(isA<UnknownSignerException>()),
      );
    });
  });

  group('through the processor', () {
    Future<({EpochProcessor proc, AlbumKeyStore aks, FakeEpochApi api})>
        stack() async {
      final responder = await newResponderIdentity();
      final aks = AlbumKeyStore(responder.store);
      await aks.initialize();
      final api = FakeEpochApi();
      final resolverAuthority = memoryAuthority(FakeAuthorityApi()
            ..notes = [
              await noteFor(admin.identity,
                  albumId: _album,
                  memberToken: _token(0x42),
                  member: responder.svc),
            ])
          .authority;
      final proc = EpochProcessor(
        api: api,
        identity: responder.svc,
        store: aks,
        directory: MemberDirectory(singletonAdminFetcher(admin)),
        senders: AuthoritySenders(
          authority: resolverAuthority,
          identity: responder.svc,
          selfToken: (_) => null,
        ),
        signerGate: tofuGate(),
      );
      authority = resolverAuthority;
      final bundle = await buildResponderBundle(
          responder: responder.svc, spkTs: 1714838400);
      final env = await admin.buildWrap(
          albumId: _album,
          epoch: 0,
          mk: Uint8List.fromList(List.filled(32, 0x3C)),
          responderBundle: bundle);
      api.putWrap(uuidStringFromBytes(_album), 0, env);
      return (proc: proc, aks: aks, api: api);
    }

    test('a first join installs the key and anchors on the inviter', () async {
      final s = await stack();
      final key = '${uuidStringFromBytes(_album)}:0';
      final env = s.api.wraps[key]!;
      s.api.wraps[key] = _withNotes(env, [await adminSelfNote()]);

      await s.proc.handleEvent(albumId: _album, epoch: 0);

      expect(await s.aks.presentEpochs(_album), [0]);
      expect(authority.chain(_album)!.currentAdmin.ikPub, admin.ikPub);
    });

    test('a note signed by someone else installs nothing', () async {
      final s = await stack();
      final key = '${uuidStringFromBytes(_album)}:0';
      // Claims the inviter's token with an attacker's keys
      final forged = await noteFor(mallory,
          albumId: _album, memberToken: admin.senderToken, member: mallory);
      s.api.wraps[key] = _withNotes(s.api.wraps[key]!, [forged]);

      await expectLater(s.proc.handleEvent(albumId: _album, epoch: 0),
          throwsA(isA<WrapVerificationException>()));
      expect(await s.aks.presentEpochs(_album), isEmpty);
      expect(authority.hasAnchor(_album), isFalse);
    });
  });
}

WrapEnvelope _withNotes(WrapEnvelope e, List<SignedNote> notes) => WrapEnvelope(
      epoch: e.epoch,
      ekPub: e.ekPub,
      wrap: e.wrap,
      senderToken: e.senderToken,
      senderSig: e.senderSig,
      opkIdxUsed: e.opkIdxUsed,
      deliveredAt: e.deliveredAt,
      senderGeneration: 1,
      senderNotes: [for (final n in notes) n.toJson()],
    );
