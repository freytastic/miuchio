import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:miuchio/crypto/primitives.dart';
import 'package:miuchio/crypto/uuid_bytes.dart';
import 'package:miuchio/crypto/wire_format.dart';
import 'package:miuchio/secure_store/key_handle_adapter.dart';

import 'album_keys.dart';
import 'epoch_api.dart';
import 'identity.dart';
import 'prekey_api.dart';
import 'prekey_bundle.dart';
import 'x3dh_session.dart';

// Initiator side of an epoch change. Album create (epoch 0) and member removal
// mint a fresh MK and wrap it for the full member set. Adding a member is not
// a rotation: InviteInitiator wraps the existing MKs for the newcomer

//   wrap          AES-GCM(X3DH secret, MK, aad = album_id ‖ u32_be(epoch))
//   sender_sig    over SHA256(album_id ‖ u32_be(epoch) ‖ wrap)
//   envelope_sig  over "epoch-set-v1" ‖ album_id ‖ u32_be(epoch) ‖
//                 member_set_hash ‖ wraps_hash

// The hashes mirror server/internal/e2ee/epoch/service.go byte for byte

class RotateRecipient {
  final Uint8List memberToken;
  // Null on member removal, where remaining members are known only by token
  final String? userId;
  // The IK the caller authenticated locally (own key or the TOFU pin). The MK
  // is wrapped only for a bundle carrying exactly this IK
  final Uint8List expectedIk;
  const RotateRecipient({
    required this.memberToken,
    required this.expectedIk,
    this.userId,
  });
}

// A server substituting a bundle to harvest the MK. Nothing is wrapped or sent
class IdentityMismatchException implements Exception {
  final Uint8List memberToken;
  const IdentityMismatchException(this.memberToken);
  @override
  String toString() => 'IdentityMismatchException(bundle IK != expected IK)';
}

class EpochRotator {
  final EpochApi _epochs;
  final PrekeyApi _prekeys;
  final IdentityService _identity;
  final AlbumKeyStore _aks;
  final MemberBundleFetcher? _memberBundles;
  final Now _now;

  EpochRotator({
    required EpochApi epochs,
    required PrekeyApi prekeys,
    required IdentityService identity,
    required AlbumKeyStore aks,
    MemberBundleFetcher? memberBundles,
    Now? now,
  })  : _epochs = epochs,
        _prekeys = prekeys,
        _identity = identity,
        _aks = aks,
        _memberBundles = memberBundles,
        _now = now ?? DateTime.now;

  Future<void> bootstrap({
    required Uint8List albumIdBytes,
    required Uint8List creatorMemberToken,
    required String creatorUserId,
  }) async {
    await rotate(
      albumIdBytes: albumIdBytes,
      epoch: 0,
      recipients: [
        RotateRecipient(
          memberToken: creatorMemberToken,
          userId: creatorUserId,
          expectedIk: await _identity.currentIkPub(),
        ),
      ],
    );
  }

  // recipients must be the full active member set, the server recomputes
  // member_set_hash in the transaction and rejects drift
  Future<void> rotate({
    required Uint8List albumIdBytes,
    required int epoch,
    required List<RotateRecipient> recipients,
  }) async {
    if (albumIdBytes.length != 16) {
      throw ArgumentError(
          'albumIdBytes must be 16 bytes, got ${albumIdBytes.length}');
    }
    if (recipients.isEmpty) {
      throw ArgumentError('recipients must be non empty');
    }
    if (epoch < 0) {
      throw ArgumentError('epoch must be >= 0, got $epoch');
    }

    final mk = Csprng.bytes(32);
    try {
      // Signing is deferred so every signature happens in one useIk call, one
      // keystore read per epoch instead of N+1
      final partials = <({
        Uint8List ekPub,
        int? opkIdx,
        Uint8List wrap,
        Uint8List senderMsg,
        Uint8List memberToken
      })>[];
      for (final r in recipients) {
        final bundle = await _fetchBundle(albumIdBytes, r);
        await bundle.verify(now: _now);
        // verify() only proves the SPK was signed by the bundle's own IK
        if (!_ctEq(bundle.ikPub, r.expectedIk)) {
          throw IdentityMismatchException(r.memberToken);
        }
        final init = await X3dhSession.initiate(
          bundle: bundle,
          albumId: albumIdBytes,
          identity: _identity,
        );
        final Uint8List wrap;
        try {
          wrap = await _wrapMK(
            sk: init.sharedSecret,
            mk: mk,
            albumIdBytes: albumIdBytes,
            epoch: epoch,
          );
        } finally {
          init.sharedSecret.fillRange(0, init.sharedSecret.length, 0);
        }
        final senderMsg = await _buildSenderMsg(albumIdBytes, epoch, wrap);

        partials.add((
          ekPub: init.ekPub,
          opkIdx: init.opkIdx,
          wrap: wrap,
          senderMsg: senderMsg,
          memberToken: r.memberToken,
        ));
      }

      final tokens = recipients.map((r) => r.memberToken).toList();
      final memberSetHash = await _memberSetHash(tokens);
      final signed = await _identity
          .useIk<({List<Uint8List> sender, Uint8List envelope})>((seed) async {
        final kp = await KeyHandleAdapter.toEd25519(seed);
        final senderSigs = <Uint8List>[];
        for (final p in partials) {
          senderSigs.add(await Sign.sign(kp, p.senderMsg));
        }
        final wraps0 = <SetEpochWrap>[
          for (var i = 0; i < partials.length; i++)
            SetEpochWrap(
              recipientToken: partials[i].memberToken,
              ekPub: partials[i].ekPub,
              opkIdxUsed: partials[i].opkIdx,
              wrap: partials[i].wrap,
              senderSig: senderSigs[i],
            )
        ];
        final wrapsHash = await _wrapsHash(wraps0);
        final envMsg =
            _buildEnvelopeMsg(albumIdBytes, epoch, memberSetHash, wrapsHash);
        final envSig = await Sign.sign(kp, envMsg);
        return (sender: senderSigs, envelope: envSig);
      });

      final wraps = <SetEpochWrap>[
        for (var i = 0; i < partials.length; i++)
          SetEpochWrap(
            recipientToken: partials[i].memberToken,
            ekPub: partials[i].ekPub,
            opkIdxUsed: partials[i].opkIdx,
            wrap: partials[i].wrap,
            senderSig: signed.sender[i],
          )
      ];
      final envelopeSig = signed.envelope;

      await _epochs.setEpoch(
        uuidFromBytes(albumIdBytes),
        SetEpochRequest(
          epoch: epoch,
          memberSetHash: memberSetHash,
          wraps: wraps,
          envelopeSig: envelopeSig,
        ),
      );

      // Idempotent if the responder path already installed the same bytes
      await _aks.installVerified(
        albumId: albumIdBytes,
        epoch: epoch,
        mk: mk,
        backfill: false,
      );
    } finally {
      mk.fillRange(0, mk.length, 0);
    }
  }

  Future<PrekeyBundle> _fetchBundle(Uint8List albumIdBytes, RotateRecipient r) {
    final userId = r.userId;
    if (userId != null) {
      return _prekeys.fetchPrekeyBundle(userId);
    }
    final fetcher = _memberBundles;
    if (fetcher == null) {
      throw StateError(
          'by-token recipient requires a MemberBundleFetcher (none wired)');
    }
    return fetcher.fetchPrekeyBundleByMemberToken(
        uuidFromBytes(albumIdBytes), r.memberToken);
  }

  Future<Uint8List> _wrapMK({
    required Uint8List sk,
    required Uint8List mk,
    required Uint8List albumIdBytes,
    required int epoch,
  }) {
    final aad = Uint8List(16 + 4);
    aad.setRange(0, 16, albumIdBytes);
    ByteData.sublistView(aad, 16).setUint32(0, epoch, Endian.big);
    return Aead.encrypt(
      version: kVerAesGcm,
      key: sk,
      plaintext: mk,
      aad: aad,
    );
  }

  Future<Uint8List> _buildSenderMsg(
      Uint8List albumIdBytes, int epoch, Uint8List wrap) async {
    final buf = Uint8List(16 + 4 + wrap.length);
    buf.setRange(0, 16, albumIdBytes);
    ByteData.sublistView(buf, 16, 20).setUint32(0, epoch, Endian.big);
    buf.setRange(20, buf.length, wrap);
    final h = await cg.Sha256().hash(buf);
    return Uint8List.fromList(h.bytes);
  }

  Uint8List _buildEnvelopeMsg(Uint8List albumIdBytes, int epoch,
      Uint8List memberSetHash, Uint8List wrapsHash) {
    final salt = _kSaltEpochSet;
    final buf = Uint8List(salt.length + 16 + 4 + 32 + 32);
    var i = 0;
    buf.setRange(i, i + salt.length, salt);
    i += salt.length;
    buf.setRange(i, i + 16, albumIdBytes);
    i += 16;
    ByteData.sublistView(buf, i, i + 4).setUint32(0, epoch, Endian.big);
    i += 4;
    buf.setRange(i, i + 32, memberSetHash);
    i += 32;
    buf.setRange(i, i + 32, wrapsHash);
    return buf;
  }
}

// Mirrors SaltEpochSet in server/internal/crypto/salts.go
final Uint8List _kSaltEpochSet = Uint8List.fromList('epoch-set-v1'.codeUnits);

// SHA256(u32_be(N) ‖ sorted tokens)
Future<Uint8List> _memberSetHash(List<Uint8List> tokens) async {
  final sorted = [...tokens]..sort(_byteCompare);
  final builder = BytesBuilder(copy: false);
  final lenBuf = Uint8List(4);
  ByteData.sublistView(lenBuf).setUint32(0, sorted.length, Endian.big);
  builder.add(lenBuf);
  for (final t in sorted) {
    builder.add(t);
  }
  final h = await cg.Sha256().hash(builder.toBytes());
  return Uint8List.fromList(h.bytes);
}

// SHA256(u32_be(N) ‖ per wrap sorted by token: token ‖ ek_pub ‖
// u32_be(opk_idx or 0xFFFFFFFF) ‖ u32_be(len) ‖ wrap ‖ u32_be(len) ‖ sender_sig)
Future<Uint8List> _wrapsHash(List<SetEpochWrap> wraps) async {
  final sorted = [...wraps]
    ..sort((a, b) => _byteCompare(a.recipientToken, b.recipientToken));
  final builder = BytesBuilder(copy: false);
  final u32 = Uint8List(4);
  ByteData.sublistView(u32).setUint32(0, sorted.length, Endian.big);
  builder.add(Uint8List.fromList(u32));
  for (final w in sorted) {
    builder.add(w.recipientToken);
    builder.add(w.ekPub);
    final idx = w.opkIdxUsed ?? 0xFFFFFFFF;
    ByteData.sublistView(u32).setUint32(0, idx, Endian.big);
    builder.add(Uint8List.fromList(u32));
    ByteData.sublistView(u32).setUint32(0, w.wrap.length, Endian.big);
    builder.add(Uint8List.fromList(u32));
    builder.add(w.wrap);
    ByteData.sublistView(u32).setUint32(0, w.senderSig.length, Endian.big);
    builder.add(Uint8List.fromList(u32));
    builder.add(w.senderSig);
  }
  final h = await cg.Sha256().hash(builder.toBytes());
  return Uint8List.fromList(h.bytes);
}

// Constant time so a substituted IK can't learn how many leading bytes matched
bool _ctEq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

int _byteCompare(Uint8List a, Uint8List b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final d = a[i] - b[i];
    if (d != 0) return d;
  }
  return a.length - b.length;
}
