import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:miuchio/crypto/primitives.dart';
import 'package:miuchio/crypto/uuid_bytes.dart';
import 'package:miuchio/crypto/wire_format.dart';
import 'package:miuchio/secure_store/key_handle_adapter.dart';

import 'album_authority.dart';
import 'album_keys.dart';
import 'authority_records.dart';
import 'epoch_rotator.dart' show IdentityMismatchException;
import 'expected_ik_resolver.dart' show SelfTokenLookup;
import 'identity.dart';
import 'invite_api.dart';
import 'prekey_api.dart';
import 'x3dh_session.dart';

typedef PinnedIkLookupFn = Uint8List? Function(
    Uint8List albumId, Uint8List memberToken);
typedef PinIkFn = Future<void> Function(
    Uint8List albumId, Uint8List memberToken, Uint8List ikPub);

// Pins the IK the album MKs were actually wrapped to. This can't stop an
// impostor bundle at first contact (only safety numbers can), but a later
// roster showing a different IK then reads as 'changed', not a first sight
class InviteIdentityPinner {
  final PinnedIkLookupFn _pinnedIk;
  final PinIkFn _pin;
  InviteIdentityPinner({
    required PinnedIkLookupFn pinnedIk,
    required PinIkFn pin,
  })  : _pinnedIk = pinnedIk,
        _pin = pin;

  Uint8List? known(Uint8List albumId, Uint8List memberToken) =>
      _pinnedIk(albumId, memberToken);

  // Never replaces an existing pin, so a substitution at re invite still trips
  // the change alarm
  Future<void> anchor(
      Uint8List albumId, Uint8List memberToken, Uint8List ikPub) async {
    if (_pinnedIk(albumId, memberToken) != null) return;
    await _pin(albumId, memberToken, ikPub);
  }
}

// One X3DH per invite, every MK from epoch 0 wrapped under that one secret.
// The invitee installs them later through EpochProcessor backfill
class InviteInitiator {
  final PrekeyApi _prekeys;
  final InviteApi _invites;
  final IdentityService _identity;
  final AlbumKeyStore _aks;
  final AlbumAuthority _authority;
  final SelfTokenLookup _selfToken;
  final InviteIdentityPinner? _pinner;
  final Now _now;

  InviteInitiator({
    required PrekeyApi prekeys,
    required InviteApi invites,
    required IdentityService identity,
    required AlbumKeyStore aks,
    required AlbumAuthority authority,
    required SelfTokenLookup selfToken,
    InviteIdentityPinner? pinner,
    Now? now,
  })  : _prekeys = prekeys,
        _invites = invites,
        _identity = identity,
        _aks = aks,
        _authority = authority,
        _selfToken = selfToken,
        _pinner = pinner,
        _now = now ?? DateTime.now;

  // Returns the new member_token minted by the server
  Future<Uint8List> inviteExistingUser({
    required String miuchioId,
    required Uint8List albumId,
  }) async {
    final bundle = await _prekeys.fetchPrekeyBundleByHandle(miuchioId);
    await bundle.verify(now: _now);

    final init = await X3dhSession.initiate(
      bundle: bundle,
      albumId: albumId,
      identity: _identity,
    );
    try {
      final epochs = await _aks.presentEpochs(albumId);
      if (epochs.isEmpty) {
        throw StateError('inviteExistingUser: no local MKs for this album');
      }
      for (var i = 0; i < epochs.length; i++) {
        if (epochs[i] != i) {
          throw StateError(
              'inviteExistingUser: local MKs not contiguous from 0: $epochs');
        }
      }

      final wraps = <Uint8List>[];
      final senderMsgs = <Uint8List>[];
      for (final e in epochs) {
        final wrap = await _aks.useMk<Uint8List>(
          albumId,
          e,
          (mk) => _wrapMk(
              sk: init.sharedSecret, mk: mk, albumId: albumId, epoch: e),
        );
        wraps.add(wrap);
        senderMsgs.add(await _senderMsg(albumId, e, wrap));
      }

      final reissued = await _notesOwed(albumId);
      MemberNote newcomer(Uint8List token, int generation) => MemberNote(
            albumId: albumId,
            memberToken: token,
            generation: generation,
            ikPub: bundle.ikPub,
            lkPub: bundle.lkPub,
            issuerTerm: reissued.term,
          );
      var note = newcomer(Csprng.bytes(32), 1);

      // One keystore read signs every message
      final signed = await _identity
          .useIk<({List<Uint8List> sender, List<Uint8List> notes})>(
              (seed) async {
        final kp = await KeyHandleAdapter.toEd25519(seed);
        return (
          sender: [for (final m in senderMsgs) await Sign.sign(kp, m)],
          notes: [
            for (final n in [note, ...reissued.notes])
              await Sign.sign(kp, n.signedBytes()),
          ],
        );
      });
      final senderSigs = signed.sender;
      final extraNotes = [
        for (var i = 0; i < reissued.notes.length; i++)
          SignedNote(reissued.notes[i], signed.notes[i + 1]),
      ];

      final envelopes = <DeliverEnvelope>[
        for (var i = 0; i < epochs.length; i++)
          DeliverEnvelope(
            epoch: epochs[i],
            wrapNonce: Uint8List.sublistView(wraps[i], 1, 1 + 12),
            wrapTagCt: Uint8List.sublistView(wraps[i], 1 + 12),
            senderSig: senderSigs[i],
          ),
      ];

      Future<Uint8List> deliver(SignedNote signedNote) =>
          _invites.deliverExistingUser(
            albumId: uuidFromBytes(albumId),
            targetMiuchioId: miuchioId,
            ekPub: init.ekPub,
            opkIdx: init.opkIdx,
            envelopes: envelopes,
            note: signedNote,
            extraNotes: extraNotes,
          );

      Uint8List token;
      try {
        token = await deliver(SignedNote(note, signed.notes[0]));
      } on MemberTokenMismatch catch (returning) {
        // An account never replaces its identity key, so a returning member
        // showing another one is a substituted bundle. Nothing is vouched for
        final known = _pinner?.known(albumId, returning.memberToken);
        if (known != null && !_eq(known, bundle.ikPub)) {
          throw IdentityMismatchException(returning.memberToken);
        }
        note = newcomer(returning.memberToken, returning.generation);
        final sig = await _identity.useIk<Uint8List>((seed) async => Sign.sign(
            await KeyHandleAdapter.toEd25519(seed), note.signedBytes()));
        token = await deliver(SignedNote(note, sig));
      }
      await _pinner?.anchor(albumId, token, bundle.ikPub);
      return token;
    } finally {
      init.sharedSecret.fillRange(0, init.sharedSecret.length, 0);
    }
  }

  // Notes under the current admin term for every member who lacks one, this
  // device included. After a handover that is everyone, which is what lets
  // the newcomer verify members it can only know through its inviter. Keys
  // are copied from notes already verified, never from the roster
  Future<({int term, List<MemberNote> notes})> _notesOwed(
      Uint8List albumId) async {
    final roster = await _authority.verifiedRoster(albumId);
    if (roster.unverified.isNotEmpty) {
      throw IdentityMismatchException(_unhex(roster.unverified.first));
    }
    final self = _selfToken(albumId);
    final notes = <MemberNote>[];
    for (final e in roster.members.entries) {
      if (e.value.issuerTerms.contains(roster.term)) continue;
      final token = _unhex(e.key);
      final mine = self != null && _eq(self, token);
      notes.add(MemberNote(
        albumId: albumId,
        memberToken: token,
        generation: e.value.generation,
        ikPub: mine ? await _identity.currentIkPub() : e.value.ikPub,
        lkPub: mine ? await _identity.currentLkPub() : e.value.lkPub,
        issuerTerm: roster.term,
      ));
    }
    return (term: roster.term, notes: notes);
  }

  static Uint8List _unhex(String s) => Uint8List.fromList([
        for (var i = 0; i < s.length; i += 2)
          int.parse(s.substring(i, i + 2), radix: 16),
      ]);

  static bool _eq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a[i] ^ b[i];
    }
    return d == 0;
  }

  // aad = album_id ‖ u32_be(epoch)
  Future<Uint8List> _wrapMk({
    required Uint8List sk,
    required Uint8List mk,
    required Uint8List albumId,
    required int epoch,
  }) {
    final aad = Uint8List(16 + 4);
    aad.setRange(0, 16, albumId);
    ByteData.sublistView(aad, 16).setUint32(0, epoch, Endian.big);
    return Aead.encrypt(version: kVerAesGcm, key: sk, plaintext: mk, aad: aad);
  }

  // SHA256(album_id ‖ u32_be(epoch) ‖ wrap)
  Future<Uint8List> _senderMsg(
      Uint8List albumId, int epoch, Uint8List wrap) async {
    final buf = Uint8List(16 + 4 + wrap.length);
    buf.setRange(0, 16, albumId);
    ByteData.sublistView(buf, 16, 20).setUint32(0, epoch, Endian.big);
    buf.setRange(20, buf.length, wrap);
    final h = await cg.Sha256().hash(buf);
    return Uint8List.fromList(h.bytes);
  }
}
