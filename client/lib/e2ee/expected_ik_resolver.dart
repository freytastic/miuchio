import 'dart:typed_data';

typedef SelfTokenLookup = Uint8List? Function(Uint8List albumId);
typedef PinnedIkLookup = Uint8List? Function(
    Uint8List albumId, Uint8List memberToken);
typedef CurrentIkLookup = Future<Uint8List> Function();
typedef PinIk = Future<void> Function(
    Uint8List albumId, Uint8List memberToken, Uint8List ikPub);
// True while this device is the only valid signer: a locally created album
// whose epoch 0 has not installed yet
typedef SoleSignerLookup = bool Function(Uint8List albumId);

// firstSight requires adopt() after the wrap signature verifies
enum SignerTrust { pinned, firstSight }

// The wrap names a token with no signer binding on an established album. Refuse
// it so a server cannot invent a token and adopt its own IK as a first sight
class UnknownSignerException implements Exception {
  final Uint8List memberToken;
  final Uint8List presentedIk;
  const UnknownSignerException(
      {required this.memberToken, required this.presentedIk});
  @override
  String toString() => 'UnknownSignerException(no local identity for signer)';
}

// The presented signer IK contradicts the binding for this member token. Fail
// closed rather than install an MK authenticated by a server chosen key
class IdentitySignerMismatchException implements Exception {
  final Uint8List memberToken;
  final Uint8List presentedIk;
  // True when our own token carries a foreign IK: there is nothing to confirm
  final bool isSelf;
  const IdentitySignerMismatchException({
    required this.memberToken,
    required this.presentedIk,
    required this.isSelf,
  });
  @override
  String toString() =>
      'IdentitySignerMismatchException(presented IK != local identity, '
      'isSelf=$isSelf)';
}

// No TOFU at rotation time, or a server could time a substituted bundle to
// the post removal rotation and receive the new MK as a first sight
class MissingIdentityPinException implements Exception {
  final Uint8List memberToken;
  const MissingIdentityPinException(this.memberToken);
  @override
  String toString() => 'MissingIdentityPinException(no pinned identity)';
}

// The narrow surface EpochProcessor drives. Two phases on purpose: the check
// happens before the wrap's signature is verified, the adopt after it
abstract class SignerGate {
  Future<SignerTrust> check(
    Uint8List albumId,
    Uint8List memberToken,
    Uint8List presentedIk, {
    required bool allowTofu,
  });
  Future<void> adopt(
      Uint8List albumId, Uint8List memberToken, Uint8List presentedIk);
}

// call() resolves the IK an MK wrap must be bound to. Our own token resolves
// to currentIkPub since "me" is never pinned, everyone else must be pinned
class ExpectedIkResolver implements SignerGate {
  final SelfTokenLookup _selfToken;
  final PinnedIkLookup _pinned;
  // Signing authority is separate from the roster pin used by call(). A plain
  // member needs the latter for removal rotation but need not be an epoch signer
  final PinnedIkLookup? _signerPinned;
  final CurrentIkLookup _currentIk;
  // Null on initiator paths, which never adopt a key
  final PinIk? _pin;
  final SoleSignerLookup? _soleSigner;

  // check() and adopt() throw on this one rather than fall back to roster pins
  ExpectedIkResolver({
    required SelfTokenLookup selfToken,
    required PinnedIkLookup pinned,
    required CurrentIkLookup currentIk,
  })  : _selfToken = selfToken,
        _pinned = pinned,
        _signerPinned = null,
        _currentIk = currentIk,
        _pin = null,
        _soleSigner = null;

  // Every responder security port is required so incomplete wiring cannot
  // silently weaken the gate
  ExpectedIkResolver.responder({
    required SelfTokenLookup selfToken,
    required PinnedIkLookup pinned,
    required PinnedIkLookup signerPinned,
    required CurrentIkLookup currentIk,
    required SoleSignerLookup soleSigner,
    required PinIk pin,
  })  : _selfToken = selfToken,
        _pinned = pinned,
        _signerPinned = signerPinned,
        _currentIk = currentIk,
        _pin = pin,
        _soleSigner = soleSigner;

  Future<Uint8List> call(Uint8List albumId, Uint8List memberToken) async {
    final self = _selfToken(albumId);
    if (self != null && _eq(self, memberToken)) return _currentIk();
    final pinned = _pinned(albumId, memberToken);
    if (pinned == null) throw MissingIdentityPinException(memberToken);
    return pinned;
  }

  // Writes nothing, first sight authority is adopted only after the signature
  // verifies
  @override
  Future<SignerTrust> check(
    Uint8List albumId,
    Uint8List memberToken,
    Uint8List presentedIk, {
    required bool allowTofu,
  }) async {
    final self = _selfToken(albumId);
    if (self != null && _eq(self, memberToken)) {
      if (_ctEq(await _currentIk(), presentedIk)) return SignerTrust.pinned;
      throw IdentitySignerMismatchException(
          memberToken: memberToken, presentedIk: presentedIk, isSelf: true);
    }
    final signerPinned = _signerPinned;
    if (signerPinned == null) {
      throw StateError(
          'check() needs the responder ports : use ExpectedIkResolver.responder');
    }
    // Before our own epoch 0 installs every peer is refused, even a bound one.
    // Gating on allowTofu makes a stale marker inert once local keys exist
    if (allowTofu && (_soleSigner?.call(albumId) ?? false)) {
      throw UnknownSignerException(
          memberToken: memberToken, presentedIk: presentedIk);
    }
    final pinned = signerPinned(albumId, memberToken);
    if (pinned != null) {
      if (_ctEq(pinned, presentedIk)) return SignerTrust.pinned;
      // Only an out-of-band markVerified may replace this signer binding
      throw IdentitySignerMismatchException(
          memberToken: memberToken, presentedIk: presentedIk, isSelf: false);
    }
    // TOFU is confined to a genuine first join, derived from local key state
    // rather than the server controlled joined flag
    if (!allowTofu) {
      throw UnknownSignerException(
          memberToken: memberToken, presentedIk: presentedIk);
    }
    return SignerTrust.firstSight;
  }

  // Must be durable before the MK installs
  @override
  Future<void> adopt(
      Uint8List albumId, Uint8List memberToken, Uint8List presentedIk) async {
    final pin = _pin;
    final signerPinned = _signerPinned;
    if (pin == null || signerPinned == null) {
      throw StateError(
          'adopt() needs the responder ports : use ExpectedIkResolver.responder');
    }
    // Compare and set: markVerified may establish a binding while signature
    // verification is awaited, and that user decision must win
    final now = signerPinned(albumId, memberToken);
    if (now != null) {
      if (_ctEq(now, presentedIk)) return;
      throw IdentitySignerMismatchException(
          memberToken: memberToken, presentedIk: presentedIk, isSelf: false);
    }
    await pin(albumId, memberToken, presentedIk);
  }

  static bool _eq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // The compare gates MK delivery, so it must not leak how many leading bytes
  // of a substituted IK matched
  static bool _ctEq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a[i] ^ b[i];
    }
    return d == 0;
  }
}
