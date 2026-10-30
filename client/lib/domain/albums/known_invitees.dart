import 'dart:convert';
import 'dart:typed_data';

import 'package:miuchio/crypto/uuid_bytes.dart';
import 'package:miuchio/data/models/album_model.dart';
import 'package:miuchio/data/storage/known_people_store.dart';
import 'package:miuchio/e2ee/identity_trust.dart';

// The server's MaxAlbumMembers: ten people in an album, the owner included
const int albumMemberCap = 10;

// Someone this phone invited before, with the album place their name and
// face can be read from today, or no name while they have not joined
class KnownInvitee {
  final String handle;
  final String? name;
  final String? albumId;
  final String? memberToken;

  const KnownInvitee({
    required this.handle,
    this.name,
    this.albumId,
    this.memberToken,
  });

  bool get hasFace => name != null && albumId != null && memberToken != null;
}

// Names each remembered person from the album they were invited to, or
// failing that from any album where their pinned identity key turns up.
// Everything here is read from this phone
List<KnownInvitee> findKnownInvitees({
  required List<KnownPerson> people,
  required List<AlbumModel> albums,
  required String? Function(String albumId, String memberToken) nameOf,
  Uint8List? Function(String hexAlbumId, String memberToken)? pinnedIk,
  Set<String> skip = const {},
}) {
  KnownInvitee? findByKey(KnownPerson p) {
    if (pinnedIk == null) return null;
    for (final a in albums) {
      final bytes = uuidToBytes(a.id);
      if (bytes == null) continue;
      for (final m in a.memberPreviews) {
        final ik = pinnedIk(hexAlbumId(bytes), m.memberToken);
        if (ik == null || base64.encode(ik) != p.ikPub) continue;
        final name = nameOf(a.id, m.memberToken);
        if (name == null) continue;
        return KnownInvitee(
            handle: p.handle,
            name: name,
            albumId: a.id,
            memberToken: m.memberToken);
      }
    }
    return null;
  }

  KnownInvitee resolve(KnownPerson p) {
    final name = nameOf(p.albumId, p.memberToken);
    if (name != null) {
      return KnownInvitee(
          handle: p.handle,
          name: name,
          albumId: p.albumId,
          memberToken: p.memberToken);
    }
    return findByKey(p) ??
        KnownInvitee(
            handle: p.handle, albumId: p.albumId, memberToken: p.memberToken);
  }

  return [
    for (final p in people)
      if (!skip.contains(p.handle)) resolve(p),
  ];
}
