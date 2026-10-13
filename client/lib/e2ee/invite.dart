import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:miuchio/crypto/primitives.dart';
import 'package:miuchio/crypto/uuid_bytes.dart';
import 'package:miuchio/crypto/wire_format.dart';
import 'package:miuchio/secure_store/key_handle_adapter.dart';

import 'album_keys.dart';
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
  final InviteIdentityPinner? _pinner;
  final Now _now;

  InviteInitiator({
    required PrekeyApi prekeys,
    required InviteApi invites,
    required IdentityService identity,
    required AlbumKeyStore aks,
    InviteIdentityPinner? pinner,
    Now? now,
  })  : _prekeys = prekeys,
        _invites = invites,
        _identity = identity,
        _aks = aks,
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

      // One keystore read signs every message
      final senderSigs = await _identity.useIk<List<Uint8List>>((seed) async {
        final kp = await KeyHandleAdapter.toEd25519(seed);
        final sigs = <Uint8List>[];
        for (final m in senderMsgs) {
          sigs.add(await Sign.sign(kp, m));
        }
        return sigs;
      });

      final envelopes = <DeliverEnvelope>[
        for (var i = 0; i < epochs.length; i++)
          DeliverEnvelope(
            epoch: epochs[i],
            wrapNonce: Uint8List.sublistView(wraps[i], 1, 1 + 12),
            wrapTagCt: Uint8List.sublistView(wraps[i], 1 + 12),
            senderSig: senderSigs[i],
          ),
      ];

      final token = await _invites.deliverExistingUser(
        albumId: uuidFromBytes(albumId),
        targetMiuchioId: miuchioId,
        ekPub: init.ekPub,
        opkIdx: init.opkIdx,
        envelopes: envelopes,
      );
      await _pinner?.anchor(albumId, token, bundle.ikPub);
      return token;
    } finally {
      init.sharedSecret.fillRange(0, init.sharedSecret.length, 0);
    }
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
