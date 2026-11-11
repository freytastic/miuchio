import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/crypto/primitives.dart';
import 'package:miuchio/e2ee/authority_records.dart';

import '../_sodium_setup.dart';

const String _katFile = '../server/test_vectors/authority_kat.json';

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hexEnc(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Future<Uint8List> _expectSigned(Map tv, Uint8List msg) async {
  expect(_hexEnc(msg), tv['expected_msg_hex'],
      reason: '${tv['name']}: msg bytes diverged');
  final kp = await Sign.fromSeed(_hex(tv['signer_seed_hex'] as String));
  final sig = await Sign.sign(kp, msg);
  expect(_hexEnc(sig), tv['expected_sig_hex'],
      reason: '${tv['name']}: sig diverged');
  return sig;
}

void main() {
  setUpAll(ensureSodium);

  final kat =
      jsonDecode(File(_katFile).readAsStringSync()) as Map<String, dynamic>;

  test('member note agrees with the server fixture byte for byte', () async {
    final vectors = (kat['notes'] as List).cast<Map>();
    expect(vectors, isNotEmpty);
    for (final tv in vectors) {
      final note = MemberNote(
        albumId: _hex(tv['album_id_hex'] as String),
        memberToken: _hex(tv['member_token_hex'] as String),
        generation: (tv['generation'] as num).toInt(),
        ikPub: _hex(tv['ik_pub_hex'] as String),
        lkPub: _hex(tv['lk_pub_hex'] as String),
        issuerTerm: (tv['issuer_term'] as num).toInt(),
      );
      await _expectSigned(tv, note.signedBytes());
    }
  });

  test('admin handover agrees with the server fixture byte for byte', () async {
    final vectors = (kat['handovers'] as List).cast<Map>();
    expect(vectors, isNotEmpty);
    for (final tv in vectors) {
      final handover = AdminHandover(
        albumId: _hex(tv['album_id_hex'] as String),
        term: (tv['term'] as num).toInt(),
        prevHash: _hex(tv['prev_hash_hex'] as String),
        oldToken: _hex(tv['old_token_hex'] as String),
        newToken: _hex(tv['new_token_hex'] as String),
        newGeneration: (tv['new_generation'] as num).toInt(),
        newIkPub: _hex(tv['new_ik_pub_hex'] as String),
        newLkPub: _hex(tv['new_lk_pub_hex'] as String),
        mode: (tv['mode'] as num).toInt(),
        deleteMedia: tv['delete_media'] as bool,
      );
      final msg = handover.signedBytes();
      final sig = await _expectSigned(tv, msg);
      expect(_hexEnc(await handoverHash(msg, sig)), tv['expected_hash_hex'],
          reason: '${tv['name']}: chain hash diverged');
    }
  });

  test('a wrong length field is refused before anything is signed', () {
    expect(
        () => MemberNote(
              albumId: Uint8List(16),
              memberToken: Uint8List(31),
              generation: 1,
              ikPub: Uint8List(32),
              lkPub: Uint8List(32),
              issuerTerm: 0,
            ).signedBytes(),
        throwsArgumentError);
  });
}
