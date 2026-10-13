import 'dart:typed_data';

// Per album roster cache that refetches on a miss

class MemberPubs {
  final Uint8List ikPub;
  final Uint8List lkPub;
  const MemberPubs({required this.ikPub, required this.lkPub});
}

class MemberRecord {
  final Uint8List memberToken;
  final Uint8List ikPub;
  final Uint8List lkPub;
  const MemberRecord({
    required this.memberToken,
    required this.ikPub,
    required this.lkPub,
  });
}

typedef MemberFetcher = Future<List<MemberRecord>> Function(Uint8List albumId);

class MemberDirectory {
  final MemberFetcher _fetch;
  final Map<String, Map<String, MemberPubs>> _cache = {};

  MemberDirectory(this._fetch);

  // Null when the token is not in the current roster
  Future<MemberPubs?> lookup(Uint8List albumId, Uint8List memberToken) async {
    final aHex = _hex(albumId);
    final tHex = _hex(memberToken);
    final cached = _cache[aHex]?[tHex];
    if (cached != null) return cached;
    final list = await _fetch(albumId);
    // Replaced wholesale so removed members fall out
    final albumCache = <String, MemberPubs>{};
    for (final m in list) {
      albumCache[_hex(m.memberToken)] =
          MemberPubs(ikPub: m.ikPub, lkPub: m.lkPub);
    }
    _cache[aHex] = albumCache;
    return albumCache[tHex];
  }

  void drop(Uint8List albumId, Uint8List memberToken) {
    _cache[_hex(albumId)]?.remove(_hex(memberToken));
  }

  // A failed wrap check may have used stale keys, so the retry needs a fresh
  // roster
  void dropAlbum(Uint8List albumId) {
    _cache.remove(_hex(albumId));
  }
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
