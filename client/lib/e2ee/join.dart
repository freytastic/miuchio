import 'dart:convert';
import 'dart:typed_data';

// "join-complete-v1" ‖ album_id(16) ‖ u32_be(epoch) ‖ ek_pub_admin(32)
// Byte identical to invite.JoinCompleteMsg in Go, pinned by join_kat_test
const _joinCompletePrefix = 'join-complete-v1';

Uint8List joinCompleteMsg(Uint8List albumId, int epoch, Uint8List ekPubAdmin) {
  final prefix = ascii.encode(_joinCompletePrefix);
  final out = Uint8List(prefix.length + 16 + 4 + ekPubAdmin.length);
  var off = 0;
  out.setRange(off, off + prefix.length, prefix);
  off += prefix.length;
  out.setRange(off, off + 16, albumId);
  off += 16;
  ByteData.sublistView(out, off, off + 4).setUint32(0, epoch, Endian.big);
  off += 4;
  out.setRange(off, out.length, ekPubAdmin);
  return out;
}
