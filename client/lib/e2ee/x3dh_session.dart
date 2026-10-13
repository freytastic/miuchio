import 'dart:typed_data';

import 'package:miuchio/crypto/primitives.dart';
import 'package:miuchio/crypto/x3dh.dart';
import 'package:miuchio/secure_store/key_handle_adapter.dart';

import 'identity.dart';
import 'prekey_bundle.dart';

// Runs X3DH with keys from IdentityService. The EK is never persisted. Bundles
// are not re verified here, callers must run PrekeyBundle.verify() first

class X3dhInitiateResult {
  // The caller must zero sharedSecret
  final Uint8List sharedSecret;
  final Uint8List ekPub;
  final int? opkIdx;
  const X3dhInitiateResult({
    required this.sharedSecret,
    required this.ekPub,
    required this.opkIdx,
  });
}

class OpkNotFoundException implements Exception {
  final int idx;
  const OpkNotFoundException(this.idx);
  @override
  String toString() => 'OpkNotFoundException(idx=$idx)';
}

abstract class X3dhSession {
  static Future<X3dhInitiateResult> initiate({
    required PrekeyBundle bundle,
    required Uint8List albumId,
    required IdentityService identity,
  }) async {
    return identity.useLk<X3dhInitiateResult>((lkPriv) async {
      final lkKp = await KeyHandleAdapter.toX25519(lkPriv);
      final ekKp = await Kex.generateX25519();

      final shared = await X3dh.initiator(
        lkSkA: lkKp,
        ekSkA: ekKp,
        lkPkB: bundle.lkPub,
        spkPkB: bundle.spkPub,
        opkPkB: bundle.opk?.keyPub,
        albumId: albumId,
      );

      return X3dhInitiateResult(
        sharedSecret: shared,
        ekPub: ekKp.publicKey,
        opkIdx: bundle.opk?.idx,
      );
    });
  }

  // A missing OPK throws instead of falling back to 3 DH, so server ledger
  // drift surfaces
  static Future<Uint8List> derive({
    required IdentityService identity,
    required Uint8List ekPub,
    required Uint8List peerLkPub,
    required int? opkIdx,
    required Uint8List albumId,
    SpkSlot spkSlot = SpkSlot.current,
  }) async {
    if (ekPub.length != 32) {
      throw ArgumentError('ekPub must be 32 bytes, got ${ekPub.length}');
    }
    if (peerLkPub.length != 32) {
      throw ArgumentError(
          'peerLkPub must be 32 bytes, got ${peerLkPub.length}');
    }

    if (opkIdx == null) {
      return _runResponder(
        identity: identity,
        opkSk: null,
        lkPkA: peerLkPub,
        ekPkA: ekPub,
        albumId: albumId,
        spkSlot: spkSlot,
      );
    }

    final opkAttempt = identity.tryUseOpk<Uint8List>(opkIdx, (opkPriv) async {
      final opkKp = await KeyHandleAdapter.toX25519(opkPriv);
      return _runResponder(
        identity: identity,
        opkSk: opkKp,
        lkPkA: peerLkPub,
        ekPkA: ekPub,
        albumId: albumId,
        spkSlot: spkSlot,
      );
    });
    if (opkAttempt == null) {
      throw OpkNotFoundException(opkIdx);
    }
    return opkAttempt;
  }
}

// Kept private, the layering test allows only X3dhSession.derive to return
// secret bytes
Future<Uint8List> _runResponder({
  required IdentityService identity,
  required X25519KeyPair? opkSk,
  required Uint8List lkPkA,
  required Uint8List ekPkA,
  required Uint8List albumId,
  SpkSlot spkSlot = SpkSlot.current,
}) {
  return identity.useLk<Uint8List>((lkPriv) async {
    final lkKp = await KeyHandleAdapter.toX25519(lkPriv);
    return identity.useSpk<Uint8List>((spkPriv) async {
      final spkKp = await KeyHandleAdapter.toX25519(spkPriv);
      return X3dh.responder(
        lkSkB: lkKp,
        spkSkB: spkKp,
        opkSkB: opkSk,
        lkPkA: lkPkA,
        ekPkA: ekPkA,
        albumId: albumId,
      );
    }, slot: spkSlot);
  });
}
