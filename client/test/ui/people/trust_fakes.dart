import 'dart:typed_data';

import 'package:miuchio/crypto/uuid_bytes.dart';
import 'package:miuchio/e2ee/identity.dart';
import 'package:miuchio/e2ee/identity_trust.dart';

class FakeIdentity implements IdentityService {
  @override
  Future<Uint8List> currentIkPub() async =>
      Uint8List.fromList(List.filled(32, 9));

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

// Per album states, and a record of which album every operation used
class FakeTrust implements IdentityTrust {
  final Map<String, Map<String, TrustState>> states;
  final List<String> numberedFor = [];
  final List<({String album, String token, Uint8List ik})> verified = [];
  int failSaves = 0;

  FakeTrust(this.states);

  static String _hex(Uint8List b) => uuidFromBytes(b);

  @override
  Future<Map<String, TrustState>> reconcile(
    Uint8List albumId,
    List<PeerIdentity> roster, {
    String? myMemberToken,
  }) async {
    final album = states[_hex(albumId)] ?? const {};
    return {
      for (final p in roster)
        if (p.memberToken != myMemberToken)
          p.memberToken: album[p.memberToken] ?? TrustState.unverified,
    };
  }

  @override
  Future<String> safetyNumber({
    required Uint8List albumId,
    required Uint8List peerIkPub,
  }) async {
    numberedFor.add(_hex(albumId));
    return '12345 67890 12345 67890 12345 67890';
  }

  @override
  Future<void> markVerified({
    required Uint8List albumId,
    required String memberToken,
    required Uint8List peerIkPub,
  }) async {
    verified.add((album: _hex(albumId), token: memberToken, ik: peerIkPub));
    if (failSaves > 0) {
      failSaves--;
      throw const VerificationNotSaved();
    }
    (states[_hex(albumId)] ??= {})[memberToken] = TrustState.verified;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}
