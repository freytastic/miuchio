import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:miuchio/crypto/primitives.dart';
import 'package:miuchio/crypto/wire_format.dart';
import 'package:miuchio/data/models/album_model.dart';

// Albums from someone else this phone has agreed to show, and names for the
// people it blocked, which the server cannot tell it
class SafetyStore extends ChangeNotifier {
  final File _file;
  final Uint8List _cacheKey;
  // Album id to the membership's joins count when it was accepted
  final Map<String, int> _accepted = {};
  final Map<String, String> _blocked = {};

  Timer? _flush;
  Future<void> _inFlight = Future.value();
  bool _writeFailed = false;

  static final Uint8List _aad =
      Uint8List.fromList('miuchio.safety-store-v1'.codeUnits);

  SafetyStore._(this._file, this._cacheKey);

  static Future<SafetyStore> open({
    File? file,
    required Uint8List cacheRootKey,
  }) async {
    final f = file ??
        File(p.join((await getApplicationSupportDirectory()).path,
            'miuchio_safety.kec'));
    final store = SafetyStore._(f, cacheRootKey);
    await store._load();
    return store;
  }

  Future<void> _load() async {
    try {
      if (!await _file.exists()) return;
      final wire = await _file.readAsBytes();
      final pt = await Aead.decrypt(wire: wire, key: _cacheKey, aad: _aad);
      final json = jsonDecode(utf8.decode(pt)) as Map<String, dynamic>;
      (json['accepted'] as Map<String, dynamic>)
          .forEach((k, v) => _accepted[k] = (v as num).toInt());
      (json['blocked'] as Map<String, dynamic>)
          .forEach((k, v) => _blocked[k] = v as String);
    } catch (_) {
      // Fails toward asking again before an album shows
      _accepted.clear();
      _blocked.clear();
    }
  }

  bool accepted(String albumId) => _accepted.containsKey(albumId);

  Future<void> accept(AlbumModel album) async {
    if (_accepted[album.id] == album.joins) return;
    _accepted[album.id] = album.joins;
    notifyListeners();
    await flush();
  }

  // Drops acceptances from an earlier membership, for a removal and re-add
  // this phone never saw
  void reconcile(Iterable<AlbumModel> albums) {
    var changed = false;
    for (final a in albums) {
      final at = _accepted[a.id];
      if (at != null && at != a.joins) {
        _accepted.remove(a.id);
        changed = true;
      }
    }
    if (!changed) return;
    notifyListeners();
    unawaited(flush());
  }

  String? blockedName(String blockId) => _blocked[blockId];

  Future<void> rememberBlock(String blockId, String? name) async {
    if (name == null || _blocked[blockId] == name) return;
    _blocked[blockId] = name;
    _scheduleFlush();
  }

  Future<void> forgetBlock(String blockId) async {
    if (_blocked.remove(blockId) == null) return;
    _scheduleFlush();
  }

  // A later invite to the same album asks again
  Future<void> forget(String albumId) async {
    if (_accepted.remove(albumId) == null && !_writeFailed) return;
    notifyListeners();
    await flush();
  }

  bool holdsAlbum(String albumId) =>
      _writeFailed || _accepted.containsKey(albumId);

  // Account deletion only. Waits out a pending write so it cannot recreate
  // the file
  Future<void> clear() async {
    _flush?.cancel();
    _accepted.clear();
    _blocked.clear();
    try {
      await _inFlight;
    } catch (_) {}
    try {
      if (await _file.exists()) await _file.delete();
    } catch (_) {}
    notifyListeners();
  }

  void _scheduleFlush() {
    _flush?.cancel();
    _flush = Timer(const Duration(milliseconds: 400), () {
      _inFlight = _inFlight.then((_) => _write());
    });
  }

  Future<void> flush() {
    _flush?.cancel();
    _inFlight = _inFlight.then((_) => _write());
    return _inFlight;
  }

  Future<void> _write() async {
    try {
      final pt = Uint8List.fromList(utf8.encode(
          jsonEncode({'accepted': _accepted, 'blocked': _blocked})));
      final wire = await Aead.encrypt(
          version: kVerAesGcm, key: _cacheKey, plaintext: pt, aad: _aad);
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsBytes(wire, flush: true);
      await tmp.rename(_file.path);
      _writeFailed = false;
    } catch (_) {
      _writeFailed = true;
    }
  }

  @override
  void dispose() {
    _flush?.cancel();
    super.dispose();
  }
}
