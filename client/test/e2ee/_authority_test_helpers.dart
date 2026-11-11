import 'dart:typed_data';

import 'package:miuchio/crypto/primitives.dart';
import 'package:miuchio/e2ee/album_authority.dart';
import 'package:miuchio/e2ee/authority_api.dart';
import 'package:miuchio/e2ee/authority_records.dart';
import 'package:miuchio/e2ee/identity.dart';
import 'package:miuchio/secure_store/key_handle_adapter.dart';

class FakeAuthorityApi implements AuthorityApi {
  int adminTerm = 0;
  List<SignedNote> notes = [];
  List<SignedHandover> handovers = [];
  int handoverFetches = 0;
  final List<Map<String, dynamic>> posted = [];
  final Map<String, HandoverOutcome> outcomes = {};

  @override
  Future<({int adminTerm, List<SignedNote> notes})> fetchNotes(
          Uint8List albumId) async =>
      (adminTerm: adminTerm, notes: List.of(notes));

  @override
  Future<List<SignedHandover>> fetchHandovers(Uint8List albumId) async {
    handoverFetches++;
    return List.of(handovers);
  }

  @override
  Future<HandoverOutcome> postHandover(
      Uint8List albumId, Map<String, dynamic> request) async {
    posted.add(request);
    return HandoverOutcome(albumId: 'album', mode: request['mode'] as int);
  }

  @override
  Future<HandoverOutcome?> handoverOutcome(String operationId) async =>
      outcomes[operationId];
}

({AlbumAuthority authority, Map<String, String> chains}) memoryAuthority(
    AuthorityApi api) {
  final chains = <String, String>{};
  return (
    authority: AlbumAuthority(
      api: api,
      load: (id) => chains[AlbumAuthority.tokenHex(id)],
      save: (id, json) async => chains[AlbumAuthority.tokenHex(id)] = json,
    ),
    chains: chains,
  );
}

Future<SignedNote> signNote(IdentityService signer, MemberNote note) async =>
    SignedNote(
      note,
      await signer.useIk<Uint8List>((seed) async => Sign.sign(
          await KeyHandleAdapter.toEd25519(seed), note.signedBytes())),
    );

// A note naming the member's own current keys
Future<SignedNote> noteFor(
  IdentityService signer, {
  required Uint8List albumId,
  required Uint8List memberToken,
  required IdentityService member,
  int generation = 1,
  int issuerTerm = 0,
}) async =>
    signNote(
      signer,
      MemberNote(
        albumId: albumId,
        memberToken: memberToken,
        generation: generation,
        ikPub: await member.currentIkPub(),
        lkPub: await member.currentLkPub(),
        issuerTerm: issuerTerm,
      ),
    );

Future<SignedHandover> signHandover(
    IdentityService signer, AdminHandover handover) async {
  final sig = await signer.useIk<Uint8List>((seed) async => Sign.sign(
      await KeyHandleAdapter.toEd25519(seed), handover.signedBytes()));
  return SignedHandover(handover, sig);
}

// The next record in a chain, linked to the one before it
Future<SignedHandover> nextHandover(
  IdentityService oldAdmin, {
  required Uint8List albumId,
  required List<SignedHandover> chain,
  required Uint8List oldToken,
  required Uint8List newToken,
  required IdentityService newAdmin,
  int newGeneration = 1,
  int mode = kHandoverStay,
}) async {
  final prev = chain.isEmpty
      ? handoverZeroHash()
      : await handoverHash(chain.last.handover.signedBytes(), chain.last.sig);
  return signHandover(
    oldAdmin,
    AdminHandover(
      albumId: albumId,
      term: chain.length + 1,
      prevHash: prev,
      oldToken: oldToken,
      newToken: newToken,
      newGeneration: newGeneration,
      newIkPub: await newAdmin.currentIkPub(),
      newLkPub: await newAdmin.currentLkPub(),
      mode: mode,
      deleteMedia: false,
    ),
  );
}
