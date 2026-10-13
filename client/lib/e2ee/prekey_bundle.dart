import 'dart:convert';
import 'dart:typed_data';

import 'package:miuchio/crypto/primitives.dart';

import 'identity.dart' show Now;

// verify() only proves the SPK was signed by the bundle's own IK. Binding that
// IK to a known identity is the caller's job

class PrekeyBundle {
  final String userId;
  final Uint8List ikPub;
  final Uint8List lkPub;
  final Uint8List spkPub;
  final Uint8List spkSig;
  final int spkTs;
  final BundleOpk? opk;

  const PrekeyBundle({
    required this.userId,
    required this.ikPub,
    required this.lkPub,
    required this.spkPub,
    required this.spkSig,
    required this.spkTs,
    this.opk,
  });

  // spk_ts may arrive widened to a double
  factory PrekeyBundle.fromJson(Map<String, dynamic> json) {
    final opkJson = json['opk'] as Map<String, dynamic>?;
    return PrekeyBundle(
      userId: json['user_id'] as String,
      ikPub: base64Decode(json['ik_pub'] as String),
      lkPub: base64Decode(json['lk_pub'] as String),
      spkPub: base64Decode(json['spk_pub'] as String),
      spkSig: base64Decode(json['spk_sig'] as String),
      spkTs: (json['spk_ts'] as num).toInt(),
      opk: opkJson == null
          ? null
          : BundleOpk(
              idx: (opkJson['idx'] as num).toInt(),
              keyPub: base64Decode(opkJson['key_pub'] as String),
            ),
    );
  }

  // Cheapest checks first. Old and future timestamps fail with different
  // reasons so a stale server reads differently from a forged stamp
  Future<void> verify({required Now now}) async {
    if (ikPub.length != 32 ||
        lkPub.length != 32 ||
        spkPub.length != 32 ||
        spkSig.length != 64) {
      throw const BundleVerificationException('length');
    }

    final nowSec = now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final delta = nowSec - spkTs;
    if (delta.abs() > _kTsSkewSeconds) {
      throw BundleVerificationException(
          delta > 0 ? 'ts_too_old' : 'ts_in_future');
    }

    final ok = await Sign.verify(ikPub, _spkSigMsg(spkPub, spkTs), spkSig);
    if (!ok) {
      throw const BundleVerificationException('sig_invalid');
    }
  }
}

class BundleOpk {
  final int idx;
  final Uint8List keyPub;
  const BundleOpk({required this.idx, required this.keyPub});
}

class BundleVerificationException implements Exception {
  // Reason codes : 'length' | 'sig_invalid' | 'ts_too_old' | 'ts_in_future'
  final String reason;
  const BundleVerificationException(this.reason);
  @override
  String toString() => 'BundleVerificationException($reason)';
}

const int _kTsSkewSeconds = 90 * 24 * 3600;

// spk_pub(32) || u64_be(spk_ts), same layout IdentityService signs
Uint8List _spkSigMsg(Uint8List spkPub, int spkTs) {
  final out = Uint8List(40);
  out.setRange(0, 32, spkPub);
  ByteData.sublistView(out, 32).setUint64(0, spkTs, Endian.big);
  return out;
}
