import 'dart:convert';
import 'dart:typed_data';

import 'package:miuchio/crypto/wire_format.dart';

class WrapEnvelope {
  // VER(1) + NONCE(12) + TAG(16) + CT(32)
  static const int wrapBlobLen = 1 + kNonceLen + kTagLen + 32;

  final int epoch;
  final Uint8List ekPub;
  final Uint8List wrap;
  final Uint8List senderToken;
  final Uint8List senderSig;
  final int? opkIdxUsed;
  final DateTime deliveredAt;

  const WrapEnvelope({
    required this.epoch,
    required this.ekPub,
    required this.wrap,
    required this.senderToken,
    required this.senderSig,
    required this.opkIdxUsed,
    required this.deliveredAt,
  });

  factory WrapEnvelope.fromJson(Map<String, dynamic> json) {
    return WrapEnvelope(
      epoch: (json['epoch'] as num).toInt(),
      ekPub: base64Decode(json['ek_pub'] as String),
      wrap: base64Decode(json['wrap'] as String),
      senderToken: base64Decode(json['sender_token'] as String),
      senderSig: base64Decode(json['sender_sig'] as String),
      opkIdxUsed: json['opk_idx_used'] == null
          ? null
          : (json['opk_idx_used'] as num).toInt(),
      deliveredAt: DateTime.parse(json['delivered_at'] as String),
    );
  }

  // Runs before any signature or AEAD work
  void verifyShape() {
    if (ekPub.length != 32 ||
        wrap.length != wrapBlobLen ||
        wrap[0] != kVerAesGcm ||
        senderToken.length != 32 ||
        senderSig.length != 64) {
      throw const WrapVerificationException('length');
    }
  }
}

class WrapVerificationException implements Exception {
  // 'length' | 'sig_invalid' | 'aead_auth_failed'
  final String reason;
  const WrapVerificationException(this.reason);
  @override
  String toString() => 'WrapVerificationException($reason)';
}
