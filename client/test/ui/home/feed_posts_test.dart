import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/ui/home/feed_posts.dart';

void main() {
  final t0 = DateTime.utc(2026, 10, 29, 12);

  MediaRecord shot(String id, String album, String who, Duration ago,
          {int? seq}) =>
      MediaRecord(
        id: id,
        albumId: album,
        uploaderToken: who,
        wrapNonce: Uint8List(12),
        wrapTagCT: Uint8List(48),
        epochTag: 1,
        blobSize: 10,
        blobSha256: Uint8List(32),
        mediaType: 'photo',
        mimeType: 'image/jpeg',
        createdAt: t0.subtract(ago),
        albumSeq: seq,
      );

  test('photos group by album, newest album first, newest photo first', () {
    final updates = groupByAlbum([
      shot('l1', 'lake', 'ana', const Duration(hours: 3)),
      shot('r1', 'road', 'bo', const Duration(minutes: 5)),
      shot('l2', 'lake', 'bo', Duration.zero),
      shot('l3', 'lake', 'ana', const Duration(days: 2)),
    ]);

    expect([for (final u in updates) u.albumId], ['lake', 'road']);
    expect([for (final p in updates.first.photos) p.id], ['l2', 'l1', 'l3']);
  });

  test('an album names each uploader once, most recent first', () {
    final update = groupByAlbum([
      shot('a', 'lake', 'ana', const Duration(hours: 1)),
      shot('b', 'lake', 'bo', Duration.zero),
      shot('c', 'lake', 'ana', const Duration(hours: 2)),
    ]).single;

    expect(update.uploaders, ['bo', 'ana']);
  });

  group('unseen photos', () {
    test('are the ones past the seen marker, never your own', () {
      final records = [
        shot('old', 'lake', 'ana', const Duration(hours: 2), seq: 3),
        shot('new', 'lake', 'ana', Duration.zero, seq: 5),
        shot('mine', 'lake', 'me', Duration.zero, seq: 4),
      ];

      final unseen = unseenIn(records, lastSeen: 3, unseen: 2, me: 'me');

      expect([for (final r in unseen) r.id], ['new']);
    });

    test('rows without a place fall back to the newest few', () {
      final records = [
        shot('a', 'lake', 'ana', const Duration(hours: 2)),
        shot('b', 'lake', 'ana', Duration.zero),
        shot('c', 'lake', 'ana', const Duration(hours: 1), seq: 9),
      ];

      final unseen = unseenIn(records, lastSeen: 8, unseen: 2);

      expect([for (final r in unseen) r.id], ['b', 'c']);
    });
  });
}
