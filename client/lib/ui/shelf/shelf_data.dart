import 'package:flutter/foundation.dart';
import 'package:miuchio/data/models/album_summary.dart';

abstract class ShelfCovers implements Listenable {
  Uint8List? bytes(String albumId, int slot);

  void ensureCover(String albumId, List<PreviewMedia> preview);

  void ensureRiffle(String albumId, List<PreviewMedia> preview);

  // Drops plaintext while preserving the reload registry
  void suspend();

  void resume();

  // Invalidates and drains album loads before cache deletion
  Future<void> forget(String albumId);
}

// Device local read state that never leaves the phone
abstract class SeenStore implements Listenable {
  int lastSeen(String albumId);

  // Distinguishes an empty known album from an unknown album
  bool knows(String albumId);

  Future<void> markSeen(String albumId, int generation);

  // Uploads by this device never count as new to its user
  Future<void> markOwn(String albumId, int generation);

  int ownThrough(String albumId, int generation);

  Future<void> forget(String albumId);
}

// Own uploads above the watermark, so others' photos between them stay new
class OwnUploads {
  final Map<String, Set<int>> _by = {};

  void add(String albumId, int generation) =>
      (_by[albumId] ??= {}).add(generation);

  // Returns the watermark moved past own generations directly above it
  int absorb(String albumId, int seen) {
    final own = _by[albumId];
    if (own == null) return seen;
    own.removeWhere((g) => g <= seen);
    while (own.remove(seen + 1)) {
      seen++;
    }
    if (own.isEmpty) _by.remove(albumId);
    return seen;
  }

  int through(String albumId, int generation) =>
      _by[albumId]?.where((g) => g <= generation).length ?? 0;

  void remove(String albumId) => _by.remove(albumId);

  void clear() => _by.clear();

  Map<String, List<int>> toJson() =>
      {for (final e in _by.entries) e.key: e.value.toList()};

  void load(Map<String, dynamic> json) {
    _by.clear();
    json.forEach((k, v) {
      final gens = {for (final g in v as List) (g as num).toInt()};
      if (gens.isNotEmpty) _by[k] = gens;
    });
  }
}

class InMemorySeenStore extends ChangeNotifier implements SeenStore {
  final Map<String, int> _seen = {};
  final OwnUploads _own = OwnUploads();

  @override
  int lastSeen(String albumId) => _seen[albumId] ?? 0;

  @override
  bool knows(String albumId) => _seen.containsKey(albumId);

  @override
  Future<void> markSeen(String albumId, int generation) async {
    final cur = _seen[albumId];
    if (cur != null && cur >= generation) return;
    _seen[albumId] = _own.absorb(albumId, generation);
    notifyListeners();
  }

  @override
  Future<void> markOwn(String albumId, int generation) async {
    final cur = _seen[albumId];
    if (cur == null || cur >= generation) return;
    _own.add(albumId, generation);
    _seen[albumId] = _own.absorb(albumId, cur);
    notifyListeners();
  }

  @override
  int ownThrough(String albumId, int generation) =>
      _own.through(albumId, generation);

  @override
  Future<void> forget(String albumId) async {
    _own.remove(albumId);
    if (_seen.remove(albumId) == null) return;
    notifyListeners();
  }
}
