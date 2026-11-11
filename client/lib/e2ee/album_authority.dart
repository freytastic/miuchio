import 'dart:convert';
import 'dart:typed_data';

import 'package:miuchio/crypto/primitives.dart';

import 'authority_api.dart';
import 'authority_records.dart';

// Decides whose keys this device accepts for an album. Trust starts at the
// admin who invited us (or ourselves, for an album made here) and moves only
// forward, through handover records each signed by the admin before. A member
// may sign a new key when an admin we trust issued a note for them. Nothing
// here trusts the roster the server lists

class AdminKey {
  final Uint8List token;
  final Uint8List ikPub;
  final Uint8List lkPub;
  final int generation;
  const AdminKey({
    required this.token,
    required this.ikPub,
    required this.lkPub,
    required this.generation,
  });

  Map<String, dynamic> toJson() => {
        'k': base64Encode(token),
        'i': base64Encode(ikPub),
        'l': base64Encode(lkPub),
        'g': generation,
      };

  factory AdminKey.fromJson(Map<String, dynamic> j) => AdminKey(
        token: base64Decode(j['k'] as String),
        ikPub: base64Decode(j['i'] as String),
        lkPub: base64Decode(j['l'] as String),
        generation: j['g'] as int,
      );
}

class AdminChain {
  // The first term this device can vouch for. Earlier admins are unknown to it
  final int anchorTerm;
  final Map<int, AdminKey> admins;
  // Hash of the record that made the latest admin, null until first seen. The
  // records link backwards, so pinning it pins every record before it
  final Uint8List? headHash;
  const AdminChain(
      {required this.anchorTerm, required this.admins, this.headHash});

  int get latestTerm => admins.keys.reduce((a, b) => a > b ? a : b);
  AdminKey get currentAdmin => admins[latestTerm]!;

  String encode() => jsonEncode({
        'a': anchorTerm,
        't': {for (final e in admins.entries) '${e.key}': e.value.toJson()},
        if (headHash != null) 'h': base64Encode(headHash!),
      });

  factory AdminChain.decode(String s) {
    final j = jsonDecode(s) as Map<String, dynamic>;
    return AdminChain(
      anchorTerm: j['a'] as int,
      admins: {
        for (final e in (j['t'] as Map<String, dynamic>).entries)
          int.parse(e.key): AdminKey.fromJson(e.value as Map<String, dynamic>),
      },
      headHash: j['h'] == null ? null : base64Decode(j['h'] as String),
    );
  }
}

// Keys an admin we trust vouched for, and under which terms
class MemberKeys {
  final Uint8List ikPub;
  final Uint8List lkPub;
  final int generation;
  final Set<int> issuerTerms;
  const MemberKeys({
    required this.ikPub,
    required this.lkPub,
    required this.generation,
    required this.issuerTerms,
  });
}

// A handover the server presented does not follow from the admin we trust
class AuthorityChainException implements Exception {
  final String reason;
  const AuthorityChainException(this.reason);
  @override
  String toString() => 'AuthorityChainException($reason)';
}

typedef AuthorityLoad = String? Function(Uint8List albumId);
typedef AuthoritySave = Future<void> Function(Uint8List albumId, String json);

class AlbumAuthority {
  final AuthorityApi _api;
  final AuthorityLoad _load;
  final AuthoritySave _save;

  AlbumAuthority({
    required AuthorityApi api,
    required AuthorityLoad load,
    required AuthoritySave save,
  })  : _api = api,
        _load = load,
        _save = save;

  // One chain change at a time per album: each reads the saved chain, so two
  // overlapping ones would let the slower save over what the faster learned
  final Map<String, Future<void>> _queue = {};

  Future<T> _serial<T>(Uint8List albumId, Future<T> Function() body) {
    final key = tokenHex(albumId);
    final run = (_queue[key] ?? Future<void>.value()).then((_) => body());
    final tail = run.then<void>((_) {}, onError: (_) {});
    _queue[key] = tail;
    tail.then((_) {
      if (identical(_queue[key], tail)) _queue.remove(key);
    });
    return run;
  }

  AdminChain? chain(Uint8List albumId) {
    final raw = _load(albumId);
    return raw == null ? null : AdminChain.decode(raw);
  }

  bool hasAnchor(Uint8List albumId) => _load(albumId) != null;

  // An album made on this device starts with us as its only authority
  Future<void> anchorCreator({
    required Uint8List albumId,
    required Uint8List selfToken,
    required Uint8List ikPub,
    required Uint8List lkPub,
  }) =>
      _serial(
          albumId,
          () => _save(
                albumId,
                AdminChain(anchorTerm: 0, admins: {
                  0: AdminKey(
                      token: selfToken,
                      ikPub: ikPub,
                      lkPub: lkPub,
                      generation: 1),
                }).encode(),
              ));

  // The inviter's own note at the term they invited this device under, found
  // through the note they signed for this device's key. A later self note of
  // the same admin is not the invitation: anchoring there would forget the
  // admins in between, and notes they issued would then fail to verify
  Future<SignedNote?> invitationNote(
    Uint8List albumId,
    List<SignedNote> senderNotes,
    Uint8List senderToken,
    int generation, {
    required Uint8List selfIk,
  }) async {
    final inviter = <int, SignedNote>{};
    for (final n in senderNotes) {
      if (!_eq(n.note.memberToken, senderToken) ||
          n.note.generation != generation) {
        continue;
      }
      if (await Sign.verify(n.note.ikPub, n.note.signedBytes(), n.sig)) {
        inviter[n.note.issuerTerm] = n;
      }
    }
    if (inviter.isEmpty) return null;
    final served = await _api.fetchNotes(albumId);
    SignedNote? best;
    for (final mine in served.notes) {
      if (!_eq(mine.note.ikPub, selfIk)) continue;
      final term = mine.note.issuerTerm;
      final self = inviter[term];
      if (self == null) continue;
      if (best != null && term >= best.note.issuerTerm) continue;
      if (await Sign.verify(
          self.note.ikPub, mine.note.signedBytes(), mine.sig)) {
        best = self;
      }
    }
    return best;
  }

  // Never replaces an anchor: only a first join may take one on trust, and
  // the caller has already verified the wrap under this note's key
  Future<void> adoptAnchor(Uint8List albumId, SignedNote selfNote) =>
      _serial(albumId, () => _adoptAnchor(albumId, selfNote));

  Future<void> _adoptAnchor(Uint8List albumId, SignedNote selfNote) async {
    if (hasAnchor(albumId)) return;
    final n = selfNote.note;
    await _save(
      albumId,
      AdminChain(anchorTerm: n.issuerTerm, admins: {
        n.issuerTerm: AdminKey(
          token: n.memberToken,
          ikPub: n.ikPub,
          lkPub: n.lkPub,
          generation: n.generation,
        ),
      }).encode(),
    );
  }

  // Extends the chain with every handover that verifies. Returns the chain as
  // it now stands, or null when this device has no anchor for the album
  Future<AdminChain?> sync(Uint8List albumId) async =>
      (await head(albumId))?.chain;

  // The chain plus the hash the next handover must sign as prev_hash
  Future<({AdminChain chain, Uint8List prevHash})?> head(Uint8List albumId) =>
      _serial(albumId, () => _head(albumId));

  Future<({AdminChain chain, Uint8List prevHash})?> _head(
      Uint8List albumId) async {
    final known = chain(albumId);
    if (known == null) return null;
    final served = await _api.fetchHandovers(albumId);
    final admins = Map<int, AdminKey>.of(known.admins);
    var latest = known.latestTerm;
    // A server holding back records it already showed us would let a stale
    // admin sign on top of an old head
    if (served.length < latest) {
      throw const AuthorityChainException('records this device saw are gone');
    }
    var prev = handoverZeroHash();
    for (var i = 0; i < served.length; i++) {
      final h = served[i].handover;
      final msg = h.signedBytes();
      if (h.term != i + 1) {
        throw const AuthorityChainException('terms are not consecutive');
      }
      if (!_eq(h.prevHash, prev)) {
        throw const AuthorityChainException('record does not chain');
      }
      prev = await handoverHash(msg, served[i].sig);
      if (h.term == known.latestTerm) {
        final pinned = known.headHash;
        if (pinned != null && !_eq(pinned, prev)) {
          throw const AuthorityChainException(
              'history this device saw changed');
        }
      }
      if (h.term <= latest) continue;
      final signer = admins[h.term - 1];
      if (signer == null ||
          !_eq(signer.token, h.oldToken) ||
          !await Sign.verify(signer.ikPub, msg, served[i].sig)) {
        throw const AuthorityChainException('not signed by the admin before');
      }
      admins[h.term] = AdminKey(
        token: h.newToken,
        ikPub: h.newIkPub,
        lkPub: h.newLkPub,
        generation: h.newGeneration,
      );
      latest = h.term;
    }
    // Term 0 has no record, so an album never handed over has nothing to pin
    final head = latest == 0 ? null : prev;
    final next = AdminChain(
        anchorTerm: known.anchorTerm, admins: admins, headHash: head);
    if (latest != known.latestTerm || known.headHash == null && head != null) {
      await _save(albumId, next.encode());
    }
    return (chain: next, prevHash: prev);
  }

  // The keys to verify a wrap from this sender with, or null when no admin
  // this device trusts vouched for that membership
  Future<MemberKeys?> verifySender(Uint8List albumId, Uint8List senderToken,
      int generation, List<SignedNote> notes) async {
    var known = chain(albumId);
    if (known == null) return null;
    final mine = [
      for (final n in notes)
        if (_eq(n.note.memberToken, senderToken) &&
            n.note.generation == generation)
          n,
    ];
    if (mine.any((n) => n.note.issuerTerm > known!.latestTerm)) {
      known = await sync(albumId) ?? known;
    }
    return _verified(known, mine);
  }

  // Every active member an admin we trust vouched for, by hex token. A member
  // missing here must not be handed a key
  Future<({int term, Map<String, MemberKeys> members, Set<String> unverified})>
      verifiedRoster(Uint8List albumId) async {
    var known = chain(albumId);
    if (known == null) {
      throw const AuthorityChainException('no anchor for this album');
    }
    final served = await _api.fetchNotes(albumId);
    if (served.adminTerm != known.latestTerm) {
      known = await sync(albumId) ?? known;
    }
    final byToken = <String, List<SignedNote>>{};
    for (final n in served.notes) {
      byToken.putIfAbsent(tokenHex(n.note.memberToken), () => []).add(n);
    }
    final members = <String, MemberKeys>{};
    final unverified = <String>{};
    for (final e in byToken.entries) {
      final keys = await _verified(known, e.value);
      if (keys == null) {
        unverified.add(e.key);
      } else {
        members[e.key] = keys;
      }
    }
    return (term: known.latestTerm, members: members, unverified: unverified);
  }

  // Notes that verify must agree on the keys, or none of them is used
  Future<MemberKeys?> _verified(
      AdminChain known, List<SignedNote> notes) async {
    MemberKeys? out;
    for (final n in notes) {
      final issuer = known.admins[n.note.issuerTerm];
      if (issuer == null) continue;
      if (!await Sign.verify(issuer.ikPub, n.note.signedBytes(), n.sig)) {
        continue;
      }
      if (out == null) {
        out = MemberKeys(
          ikPub: n.note.ikPub,
          lkPub: n.note.lkPub,
          generation: n.note.generation,
          issuerTerms: {n.note.issuerTerm},
        );
      } else if (_eq(out.ikPub, n.note.ikPub) &&
          _eq(out.lkPub, n.note.lkPub) &&
          out.generation == n.note.generation) {
        out.issuerTerms.add(n.note.issuerTerm);
      } else {
        return null;
      }
    }
    return out;
  }

  static String tokenHex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static bool _eq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a[i] ^ b[i];
    }
    return d == 0;
  }
}
