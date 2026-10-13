import 'dart:typed_data';

import 'package:miuchio/crypto/safety_numbers.dart';
import 'package:miuchio/data/storage/identity_pin_store.dart';
import 'package:miuchio/e2ee/identity.dart';

// Local TOFU state for the roster UI. Roster pins detect key changes but do not
// authorize epoch signers: only markVerified writes both trust layers
enum TrustState {
  // Pinned but never compared, TOFU can't rule out a MITM at first sight
  unverified,
  // Compared out of band and unchanged since
  verified,
  // Same member token, different ik_pub
  changed,
}

class PeerIdentity {
  // base64, stable per (user, album)
  final String memberToken;
  final Uint8List ikPub;
  const PeerIdentity({required this.memberToken, required this.ikPub});
}

String hexAlbumId(Uint8List albumId) =>
    albumId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

// Carries the new key so each later replacement raises its own alarm
typedef TrustChanged = void Function(
    Uint8List albumId, String memberToken, Uint8List newIkPub);

// The comparison matched but the write failed, so after a restart the album
// alarms again
class VerificationNotSaved implements Exception {
  const VerificationNotSaved();
}

class IdentityTrust {
  final IdentityService _identity;
  final IdentityPinStore _pins;
  final TrustChanged? _onChanged;

  IdentityTrust({
    required IdentityService identity,
    required IdentityPinStore pins,
    TrustChanged? onChanged,
  })  : _identity = identity,
        _pins = pins,
        _onChanged = onChanged;

  // Pins first sights only, never moves a pin or grants signing authority.
  // Our own row is skipped by local token, never by ik_pub, or a server could
  // silence a peer's alarm by claiming that peer's key is ours
  Future<Map<String, TrustState>> reconcile(
    Uint8List albumId,
    List<PeerIdentity> roster, {
    String? myMemberToken,
  }) async {
    final myIk = await _identity.currentIkPub();
    final album = hexAlbumId(albumId);
    final out = <String, TrustState>{};
    var pinnedAny = false;

    for (final peer in roster) {
      if (peer.memberToken == myMemberToken) continue;
      final pinned = _pins.pinnedIk(album, peer.memberToken);
      if (pinned == null) {
        _pins.pin(album, peer.memberToken, peer.ikPub);
        pinnedAny = true;
      } else if (!_eq(pinned, peer.ikPub)) {
        out[peer.memberToken] = TrustState.changed;
        _onChanged?.call(albumId, peer.memberToken, peer.ikPub);
        continue;
      }
      // Also on first sight, the same peer in a new album has a fresh token
      // but may already be verified
      out[peer.memberToken] =
          _pins.isVerified(myIkPub: myIk, peerIkPub: peer.ikPub)
              ? TrustState.verified
              : TrustState.unverified;
    }
    // Flushed now, a kill inside the debounce window would drop the baseline
    // and let a substituted key become the next first sight
    if (pinnedAny) await _pins.flush();
    return out;
  }

  Future<String> safetyNumber({
    required Uint8List albumId,
    required Uint8List peerIkPub,
  }) async {
    final myIk = await _identity.currentIkPub();
    return SafetyNumber.formatted(
        ikPubA: myIk, ikPubB: peerIkPub, albumId: albumId);
  }

  // The only path that moves a roster pin or grants signing authority outside
  // first join, there is deliberately no accept without comparing
  Future<void> markVerified({
    required Uint8List albumId,
    required String memberToken,
    required Uint8List peerIkPub,
  }) async {
    final myIk = await _identity.currentIkPub();
    final album = hexAlbumId(albumId);
    _pins.pin(album, memberToken, peerIkPub);
    _pins.pinSigner(album, memberToken, peerIkPub);
    _pins.markVerified(myIkPub: myIk, peerIkPub: peerIkPub);
    await _pins.flush();
    if (_pins.lastWriteFailed) throw const VerificationNotSaved();
  }

  // Needs both global verification and this album's matching pin
  Future<bool> isResolved({
    required Uint8List albumId,
    required String memberToken,
    required Uint8List peerIkPub,
  }) async {
    if (_pins.lastWriteFailed) return false;
    final pinned = _pins.pinnedIk(hexAlbumId(albumId), memberToken);
    if (pinned == null || !_eq(pinned, peerIkPub)) return false;
    final myIk = await _identity.currentIkPub();
    return _pins.isVerified(myIkPub: myIk, peerIkPub: peerIkPub);
  }

  Future<DateTime?> verifiedAt(Uint8List peerIkPub) async {
    final myIk = await _identity.currentIkPub();
    return _pins.verifiedAt(myIkPub: myIk, peerIkPub: peerIkPub);
  }

  // Global verification claims remain
  Future<void> forgetAlbum(Uint8List albumId) =>
      _pins.clearAlbum(hexAlbumId(albumId));

  static bool _eq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
