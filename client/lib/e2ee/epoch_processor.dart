import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:miuchio/crypto/primitives.dart';
import 'package:miuchio/crypto/uuid_bytes.dart';
import 'package:miuchio/secure_store/key_handle_adapter.dart';
import 'package:miuchio/secure_store/key_store_exceptions.dart';

import 'album_keys.dart';
import 'epoch_api.dart';
import 'expected_ik_resolver.dart';
import 'identity.dart';
import 'invite_api.dart';
import 'join.dart';
import 'member_directory.dart';
import 'wrap_envelope.dart';
import 'x3dh_session.dart';

export 'x3dh_session.dart' show OpkNotFoundException;
export 'expected_ik_resolver.dart'
    show IdentitySignerMismatchException, UnknownSignerException;

// Signer problems need an out of band comparison, the rest can be retried
enum EpochBlockReason {
  // A peer's presented IK contradicts the one pinned for that member_token
  signerMismatch,
  // An established album has no signer binding for this member token
  unknownSigner,
  // MY own token carries a foreign IK: there is nothing to confirm
  selfSignerMismatch,
  // Later epochs stay blocked behind it
  wrapUnavailable,
  verificationFailed,
  // The OPK the wrap names is gone, so the X3DH secret can never be rederived
  localKeyMissing,
  // A replayed epoch, or the same epoch arriving twice with different bytes
  replayRejected,
}

// Carries the presented key so the verification UI can't be switched to a
// different roster value after the failure
class EpochBlocked {
  final Uint8List albumId;
  final int epoch;
  final EpochBlockReason reason;
  final Uint8List? senderToken;
  final Uint8List? presentedIk;
  const EpochBlocked({
    required this.albumId,
    required this.epoch,
    required this.reason,
    this.senderToken,
    this.presentedIk,
  });
}

// Installs album MKs from epoch_changed events and cold start catch up

// For each wrap: check signer authority locally, verify the IK signature over
// SHA256(album_id ‖ u32_be(epoch) ‖ wrap), rederive the X3DH secret, open the
// MK and install it. Events are chained per album so installs never go
// backwards when the socket flaps, different albums run in parallel

typedef BackoffSchedule = Duration Function(int attempt);

const Duration _kRetry0 = Duration(milliseconds: 200);
const Duration _kRetry1 = Duration(milliseconds: 800);
const Duration _kRetry2 = Duration(milliseconds: 3200);

Duration _defaultBackoff(int attempt) {
  if (attempt == 0) return _kRetry0;
  if (attempt == 1) return _kRetry1;
  return _kRetry2;
}

class EpochProcessor {
  final EpochApi _api;
  final IdentityService _identity;
  final AlbumKeyStore _store;
  final MemberDirectory _directory;
  final SignerGate _signerGate;
  final BackoffSchedule _backoff;
  final int _maxRetries;
  // Null skips the join_complete receipt
  final InviteApi? _invites;

  // hex(albumId) to the tail of its event chain
  final Map<String, Future<void>> _chains = {};

  // Emits only after the join receipt is posted, so listeners can trust the
  // keys are durably installed
  final StreamController<Uint8List> _joined =
      StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get joinedAlbums => _joined.stream;

  // Key sync health. Both dispatch paths swallow throws, so these streams are
  // the only way a stalled album reaches the user
  final StreamController<EpochBlocked> _blocked =
      StreamController<EpochBlocked>.broadcast();
  Stream<EpochBlocked> get blocked => _blocked.stream;

  // Carries the epoch the album is now caught up TO. A stale duplicate event
  // for an older epoch must not clear a block raised by a newer one
  final StreamController<({Uint8List albumId, int epoch})> _unblocked =
      StreamController<({Uint8List albumId, int epoch})>.broadcast();
  Stream<({Uint8List albumId, int epoch})> get unblocked => _unblocked.stream;

  EpochProcessor({
    required EpochApi api,
    required IdentityService identity,
    required AlbumKeyStore store,
    required MemberDirectory directory,
    // Required, not optional: an unwired gate would silently restore the
    // server controlled verification loop this exists to break
    required SignerGate signerGate,
    InviteApi? invites,
    BackoffSchedule? backoff,
    int maxRetries = 3,
  })  : _api = api,
        _identity = identity,
        _store = store,
        _directory = directory,
        _signerGate = signerGate,
        _invites = invites,
        _backoff = backoff ?? _defaultBackoff,
        _maxRetries = maxRetries;

  // joined backfills every epoch through 'epoch' and posts join_complete
  Future<void> handleEvent({
    required Uint8List albumId,
    required int epoch,
    bool joined = false,
  }) async {
    final hex = _hexAlbum(albumId);
    final prev = _chains[hex];
    Future<void> chained() async {
      if (prev != null) {
        try {
          await prev;
        } catch (_) {
          // An earlier failure must not stop later events from running
        }
      }
      if (joined) {
        await _backfillJoin(albumId, epoch);
      } else {
        await _doHandle(albumId, epoch);
      }
      _unblocked.add((albumId: albumId, epoch: epoch));
    }

    final mine = chained();
    _chains[hex] = mine;
    try {
      await mine;
    } finally {
      if (identical(_chains[hex], mine)) _chains.remove(hex);
    }
  }

  // A failure in one album does not block the others
  Future<void> catchUpAll(List<Uint8List> albumIds) async {
    for (final id in albumIds) {
      try {
        final cur = await _api.getCurrentEpoch(uuidFromBytes(id));
        if (cur == null) continue;
        final latest = await _store.latestEpoch(id);
        if (latest < 0) {
          // No local MKs means a join whose live event was missed
          await handleEvent(albumId: id, epoch: cur.currentEpoch, joined: true);
        } else {
          await handleEvent(albumId: id, epoch: cur.currentEpoch);
        }
      } catch (_) {}
    }
  }

  // Fills every missing epoch through the announced one, including holes
  Future<void> _doHandle(Uint8List albumId, int epoch) async {
    final present = (await _store.presentEpochs(albumId)).toSet();
    final latest = await _store.latestEpoch(albumId);
    // Captured once before installing: adopting an unknown signer is only
    // defensible on a device with no keys for this album
    final allowTofu = latest < 0;
    for (var n = 0; n <= epoch; n++) {
      if (present.contains(n)) continue;
      await _installEpoch(albumId, n,
          backfill: n < latest, allowTofu: allowTofu);
    }
  }

  // The receipt signs the shared X3DH ephemeral carried on the delivered wraps
  Future<void> _backfillJoin(Uint8List albumId, int current) async {
    final albumStr = uuidFromBytes(albumId);
    // From local state, never the server's joined flag, or a forged join on an
    // established album would reopen TOFU
    final allowTofu = (await _store.latestEpoch(albumId)) < 0;
    Uint8List? ekPubAdmin;
    for (var e = 0; e <= current; e++) {
      final ek =
          await _installEpoch(albumId, e, backfill: true, allowTofu: allowTofu);
      ekPubAdmin ??= ek;
    }
    if (ekPubAdmin == null) return;
    if (_invites == null) return;
    final msg = joinCompleteMsg(albumId, current, ekPubAdmin);
    final sig = await _identity.useIk<Uint8List>((seed) async {
      final kp = await KeyHandleAdapter.toEd25519(seed);
      return Sign.sign(kp, msg);
    });
    await _invites.postJoinComplete(
      albumId: albumStr,
      epoch: current,
      ekPubAdmin: ekPubAdmin,
      sig: sig,
    );
    _joined.add(albumId);
  }

  void dispose() {
    _joined.close();
    _blocked.close();
    _unblocked.close();
  }

  // Reports the block reason, then rethrows unchanged
  Future<Uint8List> _installEpoch(Uint8List albumId, int epoch,
      {required bool backfill, required bool allowTofu}) async {
    try {
      return await _installEpochInner(albumId, epoch,
          backfill: backfill, allowTofu: allowTofu);
    } on IdentitySignerMismatchException catch (e) {
      _blocked.add(EpochBlocked(
        albumId: albumId,
        epoch: epoch,
        reason: e.isSelf
            ? EpochBlockReason.selfSignerMismatch
            : EpochBlockReason.signerMismatch,
        senderToken: e.memberToken,
        presentedIk: e.presentedIk,
      ));
      // Do not reuse the rejected roster presentation on a later retry
      _directory.drop(albumId, e.memberToken);
      rethrow;
    } on UnknownSignerException catch (e) {
      _blocked.add(EpochBlocked(
        albumId: albumId,
        epoch: epoch,
        reason: EpochBlockReason.unknownSigner,
        senderToken: e.memberToken,
        presentedIk: e.presentedIk,
      ));
      _directory.drop(albumId, e.memberToken);
      rethrow;
    } on OpkNotFoundException {
      _blocked.add(EpochBlocked(
        albumId: albumId,
        epoch: epoch,
        reason: EpochBlockReason.localKeyMissing,
      ));
      rethrow;
    } on EpochReplayException {
      _blocked.add(EpochBlocked(
        albumId: albumId,
        epoch: epoch,
        reason: EpochBlockReason.replayRejected,
      ));
      rethrow;
    } on EpochWrapNotFoundException {
      _blocked.add(EpochBlocked(
        albumId: albumId,
        epoch: epoch,
        reason: EpochBlockReason.wrapUnavailable,
      ));
      rethrow;
    } on WrapVerificationException {
      _blocked.add(EpochBlocked(
        albumId: albumId,
        epoch: epoch,
        reason: EpochBlockReason.verificationFailed,
      ));
      // Signature or AEAD failure may reflect stale roster keys: retry fresh
      _directory.dropAlbum(albumId);
      rethrow;
    }
  }

  // Returns the wrap's ek_pub for the join receipt
  Future<Uint8List> _installEpochInner(Uint8List albumId, int epoch,
      {required bool backfill, required bool allowTofu}) async {
    final albumIdStr = uuidFromBytes(albumId);
    final envelope = await _fetchWithRetry(albumIdStr, epoch);
    envelope.verifyShape();

    final pubs = await _directory.lookup(albumId, envelope.senderToken);
    if (pubs == null) {
      // The signer token is absent from the current roster
      throw const WrapVerificationException('sig_invalid');
    }

    // Trusting the server's roster IK alone would be circular. check() decides
    // authority locally and writes nothing before the signature is proven
    final trust = await _signerGate
        .check(albumId, envelope.senderToken, pubs.ikPub, allowTofu: allowTofu);

    final msg = await _msgToSign(albumId, epoch, envelope.wrap);
    final ok = await Sign.verify(pubs.ikPub, msg, envelope.senderSig);
    if (!ok) throw const WrapVerificationException('sig_invalid');

    if (trust == SignerTrust.firstSight) {
      await _signerGate.adopt(albumId, envelope.senderToken, pubs.ikPub);
    }

    // Pending covers an ambiguous rotation, previous and archived cover
    // delayed wraps
    final aad = _aad(albumId, epoch);
    var vanished = false;
    Future<Uint8List?> attempt(SpkSlot slot) async {
      final r =
          await _unwrapWithSpk(albumId, epoch, envelope, pubs, aad, slot: slot);
      vanished = vanished || r.vanished;
      return r.mk;
    }

    Uint8List? mk = await attempt(SpkSlot.current);
    if (mk == null && _identity.hasPendingSpk) {
      mk = await attempt(SpkSlot.pending);
    }
    if (mk == null && _identity.hasPreviousSpk) {
      mk = await attempt(SpkSlot.previous);
    }
    if (mk == null && _identity.hasArchivedSpk) {
      mk = await attempt(SpkSlot.archived);
    }
    // Reconciliation may have promoted a vanished slot after current was tried
    if (mk == null && vanished) {
      mk = await attempt(SpkSlot.current);
    }
    if (mk == null) {
      throw const WrapVerificationException('aead_auth_failed');
    }
    try {
      await _store.installVerified(
        albumId: albumId,
        epoch: epoch,
        mk: mk,
        backfill: backfill,
      );
    } finally {
      mk.fillRange(0, mk.length, 0);
    }
    return envelope.ekPub;
  }

  // Null MK on auth failure. vanished marks a slot that reconciliation removed
  // between the presence check and the read
  Future<({Uint8List? mk, bool vanished})> _unwrapWithSpk(
    Uint8List albumId,
    int epoch,
    WrapEnvelope envelope,
    MemberPubs pubs,
    Uint8List aad, {
    required SpkSlot slot,
  }) async {
    Uint8List? sk;
    try {
      sk = await X3dhSession.derive(
        identity: _identity,
        ekPub: envelope.ekPub,
        peerLkPub: pubs.lkPub,
        opkIdx: envelope.opkIdxUsed,
        albumId: albumId,
        spkSlot: slot,
      );
      try {
        return (
          mk: await Aead.decrypt(wire: envelope.wrap, key: sk, aad: aad),
          vanished: false
        );
      } on AeadAuthFailed {
        return (mk: null, vanished: false);
      }
    } on StateError {
      // Reconciliation cleared the label
      if (slot == SpkSlot.current) rethrow;
      return (mk: null, vanished: true);
    } on KeyNotFoundException {
      // Reconciliation deleted the replaced handle
      if (slot == SpkSlot.current) rethrow;
      return (mk: null, vanished: true);
    } finally {
      if (sk != null) sk.fillRange(0, sk.length, 0);
    }
  }

  Future<WrapEnvelope> _fetchWithRetry(String albumId, int epoch) async {
    for (var i = 0;; i++) {
      try {
        return await _api.getWrap(albumId, epoch);
      } on EpochWrapNotFoundException {
        if (i >= _maxRetries - 1) rethrow;
        await Future.delayed(_backoff(i));
      }
    }
  }
}

// album_id(16) ‖ u32_be(epoch)
Uint8List _aad(Uint8List albumId, int epoch) {
  final out = Uint8List(16 + 4);
  out.setRange(0, 16, albumId);
  ByteData.sublistView(out, 16, 20).setUint32(0, epoch, Endian.big);
  return out;
}

Future<Uint8List> _msgToSign(
    Uint8List albumId, int epoch, Uint8List wrap) async {
  final buf = Uint8List(16 + 4 + wrap.length);
  buf.setRange(0, 16, albumId);
  ByteData.sublistView(buf, 16, 20).setUint32(0, epoch, Endian.big);
  buf.setRange(20, buf.length, wrap);
  final h = await cg.Sha256().hash(buf);
  return Uint8List.fromList(h.bytes);
}

String _hexAlbum(Uint8List albumId) =>
    albumId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
