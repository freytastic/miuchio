import 'package:miuchio/e2ee/media_record.dart';

// One album's new photos, as one section of the feed
class AlbumUpdate {
  final String albumId;
  // Newest first
  final List<MediaRecord> photos;

  AlbumUpdate(this.albumId, this.photos);

  DateTime get at => photos.first.createdAt;

  // Who added them, most recent first, each once
  List<String> get uploaders => [
        ...{for (final p in photos) p.uploaderToken}
      ];
}

// The feed reads album by album, the album with the newest photo first
List<AlbumUpdate> groupByAlbum(Iterable<MediaRecord> records) {
  final sorted = [...records]
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  final byAlbum = <String, AlbumUpdate>{};
  for (final r in sorted) {
    (byAlbum[r.albumId] ??= AlbumUpdate(r.albumId, [])).photos.add(r);
  }
  return byAlbum.values.toList();
}

// Photos someone else added since this phone last saw the album. Each photo
// carries its place in the album's upload count; older rows without one fall
// back to the newest photos, as many as the shelf counts as unseen
List<MediaRecord> unseenIn(
  List<MediaRecord> records, {
  required int lastSeen,
  required int unseen,
  String? me,
}) {
  final others = [
    for (final r in records)
      if (r.uploaderToken != me) r
  ];
  if (others.every((r) => r.albumSeq != null)) {
    return [
      for (final r in others)
        if (r.albumSeq! > lastSeen) r
    ];
  }
  if (unseen <= 0) return const [];
  final newest = [...others]
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return newest.take(unseen).toList();
}
