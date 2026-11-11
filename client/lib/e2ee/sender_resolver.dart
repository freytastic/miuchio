import 'dart:typed_data';

import 'album_authority.dart';
import 'authority_records.dart';
import 'expected_ik_resolver.dart';
import 'identity.dart';
import 'member_directory.dart';
import 'wrap_envelope.dart';

class ResolvedSender {
  final MemberPubs pubs;
  // True when an admin this device trusts vouched for the sender, or the
  // sender is this device. False means a first join taking the inviter on trust
  final bool vouched;
  // Makes that first trust durable. Runs after the wrap signature verifies
  // and before the key installs
  final Future<void> Function()? adopt;
  const ResolvedSender({required this.pubs, required this.vouched, this.adopt});
}

// Finds the keys a wrap must verify under. Null means nothing at all names
// the sender, an UnknownSignerException means something does but no admin this
// device trusts stands behind it
abstract class SenderResolver {
  Future<ResolvedSender?> resolve(Uint8List albumId, WrapEnvelope envelope,
      {required bool allowTofu});
}

class AuthoritySenders implements SenderResolver {
  final AlbumAuthority _authority;
  final IdentityService _identity;
  final SelfTokenLookup _selfToken;

  AuthoritySenders({
    required AlbumAuthority authority,
    required IdentityService identity,
    required SelfTokenLookup selfToken,
  })  : _authority = authority,
        _identity = identity,
        _selfToken = selfToken;

  @override
  Future<ResolvedSender?> resolve(Uint8List albumId, WrapEnvelope envelope,
      {required bool allowTofu}) async {
    final sender = envelope.senderToken;
    final self = _selfToken(albumId);
    if (self != null && _eq(self, sender)) {
      return ResolvedSender(
        pubs: MemberPubs(
          ikPub: await _identity.currentIkPub(),
          lkPub: await _identity.currentLkPub(),
        ),
        vouched: true,
      );
    }

    final notes = [
      for (final n in envelope.senderNotes) SignedNote.fromJson(albumId, n),
    ];
    final presented = notes.isEmpty ? Uint8List(0) : notes.first.note.ikPub;

    if (_authority.hasAnchor(albumId)) {
      final keys = await _authority.verifySender(
          albumId, sender, envelope.senderGeneration, notes);
      if (keys == null) {
        throw UnknownSignerException(
            memberToken: sender, presentedIk: presented);
      }
      return ResolvedSender(
        pubs: MemberPubs(ikPub: keys.ikPub, lkPub: keys.lkPub),
        vouched: true,
      );
    }

    // No anchor on a device that already holds keys is not a first join, and
    // taking a signer on trust there would let the server pick one
    if (!allowTofu) {
      throw UnknownSignerException(memberToken: sender, presentedIk: presented);
    }
    final inviter = await _authority.invitationNote(
        albumId, notes, sender, envelope.senderGeneration,
        selfIk: await _identity.currentIkPub());
    if (inviter == null) return null;
    return ResolvedSender(
      pubs: MemberPubs(ikPub: inviter.note.ikPub, lkPub: inviter.note.lkPub),
      vouched: false,
      adopt: () => _authority.adoptAnchor(albumId, inviter),
    );
  }

  static bool _eq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
