import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/data/models/album_model.dart';
import 'package:miuchio/data/models/album_summary.dart';
import 'package:miuchio/data/storage/known_people_store.dart';
import 'package:miuchio/domain/albums/known_invitees.dart';

void main() {
  const albumA = '11111111-1111-1111-1111-111111111111';
  const albumB = '22222222-2222-2222-2222-222222222222';
  final bobIk = Uint8List.fromList(List.filled(32, 7));

  KnownPerson bob({String album = albumA, String token = 'tA'}) => KnownPerson(
        handle: 'BOBB2345',
        ikPub: base64.encode(bobIk),
        albumId: album,
        memberToken: token,
        invitedAt: DateTime(2026, 1, 1),
      );

  AlbumModel album(String id, List<String> tokens) => AlbumModel(
        id: id,
        nameCt: null,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        memberPreviews: [for (final t in tokens) MemberPreview(memberToken: t)],
      );

  test('someone named in the album they were invited to keeps that place', () {
    final found = findKnownInvitees(
      people: [bob()],
      albums: [album(albumA, ['tA'])],
      nameOf: (a, t) => a == albumA && t == 'tA' ? 'Bob' : null,
    );

    expect(found.single.name, 'Bob');
    expect(found.single.albumId, albumA);
    expect(found.single.hasFace, isTrue);
  });

  test('a pinned key finds them in another album once they joined there',
      () {
    final found = findKnownInvitees(
      people: [bob()],
      albums: [album(albumA, ['tA']), album(albumB, ['tB'])],
      nameOf: (a, t) => a == albumB && t == 'tB' ? 'Bob' : null,
      pinnedIk: (_, t) => t == 'tB' ? bobIk : null,
    );

    expect(found.single.name, 'Bob');
    expect(found.single.albumId, albumB);
    expect(found.single.memberToken, 'tB');
  });

  test('someone who never joined has no name and no face', () {
    final found = findKnownInvitees(
      people: [bob()],
      albums: [album(albumA, ['tA'])],
      nameOf: (_, __) => null,
      pinnedIk: (_, __) => null,
    );

    expect(found.single.handle, 'BOBB2345');
    expect(found.single.name, isNull);
    expect(found.single.hasFace, isFalse);
  });

  test('skipped handles are left out', () {
    final found = findKnownInvitees(
      people: [bob()],
      albums: const [],
      nameOf: (_, __) => 'Bob',
      skip: {'BOBB2345'},
    );

    expect(found, isEmpty);
  });
}
