import 'dart:typed_data';

import 'package:miuchio/crypto/primitives.dart';
import 'package:miuchio/crypto/uuid_bytes.dart';
import 'package:miuchio/data/api/api_error.dart';
import 'package:miuchio/secure_store/key_handle_adapter.dart';

import 'album_authority.dart';
import 'authority_api.dart';
import 'authority_records.dart';
import 'identity.dart';

// A signed handover sent or about to be sent. The exact request is kept so a
// retry can never become a different handover
class PendingHandover {
  final String albumId;
  final String operationId;
  final Map<String, dynamic> request;
  const PendingHandover({
    required this.albumId,
    required this.operationId,
    required this.request,
  });

  Map<String, dynamic> toJson() =>
      {'album_id': albumId, 'operation_id': operationId, 'request': request};

  static PendingHandover? tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final album = json['album_id'];
    final op = json['operation_id'];
    final req = json['request'];
    if (album is! String || op is! String || req is! Map<String, dynamic>) {
      return null;
    }
    return PendingHandover(albumId: album, operationId: op, request: req);
  }
}

// Must outlive the album's own wipe, a committed leave is finished from it
abstract class HandoverMarkerStore {
  Future<List<PendingHandover>> read();
  Future<void> write(PendingHandover pending);
  Future<void> clear(String albumId);
}

class HandoverException implements Exception {
  final String reason;
  const HandoverException(this.reason);
  @override
  String toString() => 'HandoverException($reason)';
}

class AdminHandoverCoordinator {
  final AuthorityApi _api;
  final AlbumAuthority _authority;
  final IdentityService _identity;
  final HandoverMarkerStore _marker;
  final Future<void> Function(Uint8List albumId) _wipeLocalAlbum;
  final String Function() _newOperationId;

  AdminHandoverCoordinator({
    required AuthorityApi api,
    required AlbumAuthority authority,
    required IdentityService identity,
    required HandoverMarkerStore marker,
    required Future<void> Function(Uint8List albumId) wipeLocalAlbum,
    required String Function() newOperationId,
  })  : _api = api,
        _authority = authority,
        _identity = identity,
        _marker = marker,
        _wipeLocalAlbum = wipeLocalAlbum,
        _newOperationId = newOperationId;

  Future<HandoverOutcome> handOver({
    required Uint8List albumId,
    required Uint8List selfToken,
    required Uint8List successorToken,
    required bool leave,
    bool deleteMedia = false,
  }) async {
    final albumStr = uuidFromBytes(albumId);
    // An earlier attempt settles first, if it landed this device is no
    // longer the admin and the check below refuses
    for (final p in await _marker.read()) {
      if (p.albumId != albumStr) continue;
      try {
        if (await _settle(p) == null) {
          throw const HandoverException('earlier handover not confirmed');
        }
      } on ApiError catch (_) {}
    }

    final head = await _authority.head(albumId);
    if (head == null) throw const HandoverException('no anchor');
    final admin = head.chain.currentAdmin;
    if (!_eq(admin.token, selfToken)) {
      throw const HandoverException('not the admin');
    }
    // The successor's keys come from a note this device verified, so the
    // server cannot swap in keys of its choosing
    final roster = await _authority.verifiedRoster(albumId);
    final keys = roster.members[AlbumAuthority.tokenHex(successorToken)];
    if (keys == null || _eq(successorToken, selfToken)) {
      throw const HandoverException('successor not vouched for');
    }

    final record = AdminHandover(
      albumId: albumId,
      term: head.chain.latestTerm + 1,
      prevHash: head.prevHash,
      oldToken: selfToken,
      newToken: successorToken,
      newGeneration: keys.generation,
      newIkPub: keys.ikPub,
      newLkPub: keys.lkPub,
      mode: leave ? kHandoverLeave : kHandoverStay,
      deleteMedia: leave && deleteMedia,
    );
    final sig = await _identity.useIk<Uint8List>((seed) async => Sign.sign(
        await KeyHandleAdapter.toEd25519(seed), record.signedBytes()));
    final op = _newOperationId();
    final pending = PendingHandover(
      albumId: albumStr,
      operationId: op,
      request:
          handoverRequest(signed: SignedHandover(record, sig), operationId: op),
    );
    // No request leaves without a marker, or a lost response after a
    // committed leave strands the album on this phone
    await _marker.write(pending);
    final outcome = await _settle(pending, fresh: true);
    if (outcome == null) {
      throw const HandoverException('not confirmed');
    }
    return outcome;
  }

  // Finishes every handover a lost response or a closed app left open
  Future<void> resume() async {
    for (final p in await _marker.read()) {
      try {
        await _settle(p);
      } catch (_) {}
    }
  }

  // Null while the server's answer is unknown, the marker then stays
  Future<HandoverOutcome?> _settle(PendingHandover p,
      {bool fresh = false}) async {
    // A committed leave ends the membership, so a replay would be refused at
    // the album's door before the server could recognize the operation
    if (!fresh) {
      final done = await _lookup(p, fresh: false);
      if (done != null) return done;
    }
    final albumId = uuidToBytes(p.albumId)!;
    HandoverOutcome outcome;
    try {
      outcome = await _api.postHandover(albumId, p.request);
    } on ApiError catch (e) {
      final done = await _lookup(p, fresh: fresh);
      if (done != null) return done;
      // These say nothing about the handover itself. An earlier send may
      // still land, so the next connect looks again
      if (e.httpStatus >= 500 ||
          e.httpStatus == 401 ||
          e.code == 'E_MEMBER_REVOKED') {
        return null;
      }
      await _marker.clear(p.albumId);
      rethrow;
    } catch (_) {
      return _lookup(p, fresh: fresh);
    }
    await _finish(p, outcome, fresh: fresh);
    return outcome;
  }

  Future<HandoverOutcome?> _lookup(PendingHandover p,
      {required bool fresh}) async {
    final HandoverOutcome? outcome;
    try {
      outcome = await _api.handoverOutcome(p.operationId);
    } catch (_) {
      return null;
    }
    if (outcome != null) await _finish(p, outcome, fresh: fresh);
    return outcome;
  }

  // A marker settled later may belong to a membership that already ended and
  // was followed by a new invite, wiping then would destroy the new one's keys
  Future<void> _finish(PendingHandover p, HandoverOutcome outcome,
      {required bool fresh}) async {
    final albumId = uuidToBytes(p.albumId)!;
    if (outcome.left) {
      if (fresh || !await _memberNow(albumId)) {
        try {
          await _wipeLocalAlbum(albumId);
        } catch (_) {
          // The marker retries the wipe at the next connect
          return;
        }
      }
    } else {
      try {
        await _authority.sync(albumId);
      } catch (_) {}
    }
    await _marker.clear(p.albumId);
  }

  // Only an explicit refusal proves the membership ended. Anything else
  // throws, and the marker waits for an answer
  Future<bool> _memberNow(Uint8List albumId) async {
    try {
      await _api.fetchHandovers(albumId);
      return true;
    } on ApiError catch (e) {
      if (e.code == 'E_NOT_MEMBER' || e.code == 'E_MEMBER_REVOKED') {
        return false;
      }
      rethrow;
    }
  }

  static bool _eq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
