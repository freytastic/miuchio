import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:miuchio/crypto/wire_format.dart';

// Both layouts mirror server/internal/e2ee/authority/records.go byte for byte,
// pinned by authority_kat_test

const int kPermRotate = 0x01;
const int kHandoverStay = 1;
const int kHandoverLeave = 2;

// An admin's statement that one membership may rotate. generation is the
// membership's joins counter, so a rejoin on the same token needs a new one
class MemberNote {
  final Uint8List albumId;
  final Uint8List memberToken;
  final int generation;
  final Uint8List ikPub;
  final Uint8List lkPub;
  final int issuerTerm;
  const MemberNote({
    required this.albumId,
    required this.memberToken,
    required this.generation,
    required this.ikPub,
    required this.lkPub,
    required this.issuerTerm,
  });

  // "member-note-v1" ‖ album_id(16) ‖ member_token(32) ‖ u32_be(generation) ‖
  // ik_pub(32) ‖ lk_pub(32) ‖ u32_be(issuer_term) ‖ perm(1)
  Uint8List signedBytes() {
    final b = BytesBuilder(copy: false)
      ..add(kSaltMemberNote)
      ..add(_fixed(albumId, 16, 'albumId'))
      ..add(_fixed(memberToken, 32, 'memberToken'))
      ..add(_u32(generation))
      ..add(_fixed(ikPub, 32, 'ikPub'))
      ..add(_fixed(lkPub, 32, 'lkPub'))
      ..add(_u32(issuerTerm))
      ..addByte(kPermRotate);
    return b.toBytes();
  }
}

class SignedNote {
  final MemberNote note;
  final Uint8List sig;
  const SignedNote(this.note, this.sig);

  factory SignedNote.fromJson(Uint8List albumId, Map<String, dynamic> json) =>
      SignedNote(
        MemberNote(
          albumId: albumId,
          memberToken: base64Decode(json['member_token'] as String),
          generation: (json['generation'] as num).toInt(),
          ikPub: base64Decode(json['ik_pub'] as String),
          lkPub: base64Decode(json['lk_pub'] as String),
          issuerTerm: (json['issuer_term'] as num).toInt(),
        ),
        base64Decode(json['sig'] as String),
      );

  Map<String, dynamic> toJson() => {
        'member_token': base64Encode(note.memberToken),
        'generation': note.generation,
        'issuer_term': note.issuerTerm,
        'ik_pub': base64Encode(note.ikPub),
        'lk_pub': base64Encode(note.lkPub),
        'sig': base64Encode(sig),
      };
}

// The outgoing admin's statement that newToken holds term
class AdminHandover {
  final Uint8List albumId;
  final int term;
  final Uint8List prevHash;
  final Uint8List oldToken;
  final Uint8List newToken;
  final int newGeneration;
  final Uint8List newIkPub;
  final Uint8List newLkPub;
  final int mode;
  final bool deleteMedia;
  const AdminHandover({
    required this.albumId,
    required this.term,
    required this.prevHash,
    required this.oldToken,
    required this.newToken,
    required this.newGeneration,
    required this.newIkPub,
    required this.newLkPub,
    required this.mode,
    required this.deleteMedia,
  });

  // "admin-handover-v1" ‖ album_id(16) ‖ u32_be(term) ‖ prev_hash(32) ‖
  // old_token(32) ‖ new_token(32) ‖ u32_be(new_generation) ‖ new_ik_pub(32) ‖
  // new_lk_pub(32) ‖ mode(1) ‖ delete_media(1)
  Uint8List signedBytes() {
    if (mode != kHandoverStay && mode != kHandoverLeave) {
      throw ArgumentError('mode must be stay or leave, got $mode');
    }
    final b = BytesBuilder(copy: false)
      ..add(kSaltAdminHandover)
      ..add(_fixed(albumId, 16, 'albumId'))
      ..add(_u32(term))
      ..add(_fixed(prevHash, 32, 'prevHash'))
      ..add(_fixed(oldToken, 32, 'oldToken'))
      ..add(_fixed(newToken, 32, 'newToken'))
      ..add(_u32(newGeneration))
      ..add(_fixed(newIkPub, 32, 'newIkPub'))
      ..add(_fixed(newLkPub, 32, 'newLkPub'))
      ..addByte(mode)
      ..addByte(deleteMedia ? 1 : 0);
    return b.toBytes();
  }
}

class SignedHandover {
  final AdminHandover handover;
  final Uint8List sig;
  const SignedHandover(this.handover, this.sig);

  factory SignedHandover.fromJson(
          Uint8List albumId, Map<String, dynamic> json) =>
      SignedHandover(
        AdminHandover(
          albumId: albumId,
          term: (json['term'] as num).toInt(),
          prevHash: base64Decode(json['prev_hash'] as String),
          oldToken: base64Decode(json['old_token'] as String),
          newToken: base64Decode(json['new_token'] as String),
          newGeneration: (json['new_generation'] as num).toInt(),
          newIkPub: base64Decode(json['new_ik_pub'] as String),
          newLkPub: base64Decode(json['new_lk_pub'] as String),
          mode: (json['mode'] as num).toInt(),
          deleteMedia: json['delete_media'] as bool,
        ),
        base64Decode(json['sig'] as String),
      );
}

// The first handover of an album chains from zeros
Uint8List handoverZeroHash() => Uint8List(32);

// SHA256(msg ‖ sig), the link the next handover signs
Future<Uint8List> handoverHash(Uint8List msg, Uint8List sig) async {
  final h = await cg.Sha256().hash([...msg, ...sig]);
  return Uint8List.fromList(h.bytes);
}

Uint8List _u32(int v) {
  if (v < 0 || v > 0xFFFFFFFF) throw ArgumentError('u32 out of range: $v');
  final out = Uint8List(4);
  ByteData.sublistView(out).setUint32(0, v, Endian.big);
  return out;
}

Uint8List _fixed(Uint8List b, int len, String name) {
  if (b.length != len) {
    throw ArgumentError('$name must be $len bytes, got ${b.length}');
  }
  return b;
}
