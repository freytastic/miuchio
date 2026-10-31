import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:miuchio/crypto/primitives.dart';
import 'package:miuchio/crypto/wire_format.dart';
import 'package:miuchio/data/models/cover_ref.dart';
import 'package:miuchio/diagnostics/trace.dart';

// Downloads and opens an album's uploaded cover. Null when it does not verify
typedef FetchCover = Future<Uint8List?> Function(String albumId, CoverRef ref);

const Duration _retryAfter = Duration(minutes: 1);

// Opened uploaded covers, resealed under the device cache key. One file per
// album, under a hashed name so the directory does not reveal album ids
class CoverCache extends ChangeNotifier {
  final Directory _root;
  final Uint8List _cacheKey;
  final FetchCover _fetch;

  final Map<String, ({String coverId, Uint8List jpeg})> _memory = {};
  final Set<String> _loading = {};
  final Map<String, DateTime> _failedAt = {};
  // Bumped by every clear so an in flight load cannot write back afterwards
  int _gen = 0;

  static final Uint8List _aad =
      Uint8List.fromList('miuchio.cover-cache-v1'.codeUnits);

  CoverCache._(this._root, this._cacheKey, this._fetch);

  static Future<CoverCache> open({
    Directory? root,
    required Uint8List cacheRootKey,
    required FetchCover fetch,
  }) async {
    final dir = root ??
        Directory(p.join((await getApplicationSupportDirectory()).path,
            'miuchio_vault', 'covers'));
    return CoverCache._(dir, cacheRootKey, fetch);
  }

  Uint8List? peek(String albumId, String coverId) {
    final hit = _memory[albumId];
    return hit != null && hit.coverId == coverId ? hit.jpeg : null;
  }

  // Safe to call from build: loads at most once per cover and notifies later
  void ensure(String albumId, CoverRef ref) {
    if (!ref.isUpload || peek(albumId, ref.coverId) != null) return;
    if (_loading.contains(ref.coverId)) return;
    final failed = _failedAt[ref.coverId];
    if (failed != null && DateTime.now().difference(failed) < _retryAfter) {
      return;
    }
    _loading.add(ref.coverId);
    unawaited(
        _load(albumId, ref).whenComplete(() => _loading.remove(ref.coverId)));
  }

  // The owner already holds the plaintext it just sealed, so it never
  // downloads its own upload back
  Future<void> remember(String albumId, String coverId, Uint8List jpeg) async {
    final gen = _gen;
    _memory[albumId] = (coverId: coverId, jpeg: jpeg);
    notifyListeners();
    await _write(await _fileFor(albumId), coverId, jpeg, gen);
  }

  Future<void> _load(String albumId, CoverRef ref) async {
    final gen = _gen;
    try {
      final file = await _fileFor(albumId);
      var jpeg = await _read(file, ref.coverId);
      final fromDisk = jpeg != null;
      jpeg ??= await _fetch(albumId, ref);
      if (gen != _gen) return;
      if (jpeg == null) {
        Trace.event('cover.open',
            fields: {'album': Trace.id(albumId), 'result': 'refused'});
        _failedAt[ref.coverId] = DateTime.now();
        return;
      }
      _memory[albumId] = (coverId: ref.coverId, jpeg: jpeg);
      _failedAt.remove(ref.coverId);
      notifyListeners();
      if (!fromDisk) await _write(file, ref.coverId, jpeg, gen);
    } catch (e) {
      Trace.event('cover.open',
          fields: {'album': Trace.id(albumId), 'result': Trace.reasonOf(e)});
      _failedAt[ref.coverId] = DateTime.now();
    }
  }

  Future<void> clearAlbum(String albumId) async {
    _gen++;
    _memory.remove(albumId);
    await _delete(await _fileFor(albumId));
    notifyListeners();
  }

  Future<void> clearAll() async {
    _gen++;
    _memory.clear();
    _failedAt.clear();
    await _delete(_root);
    notifyListeners();
  }

  Future<bool> holdsAlbum(String albumId) async =>
      _memory.containsKey(albumId) || await (await _fileFor(albumId)).exists();

  Future<Uint8List?> _read(File file, String coverId) async {
    try {
      if (!await file.exists()) return null;
      final pt = await Aead.decrypt(
          wire: await file.readAsBytes(), key: _cacheKey, aad: _aad);
      final j = jsonDecode(utf8.decode(pt)) as Map<String, dynamic>;
      if (j['id'] != coverId) return null;
      return base64.decode(j['jpeg'] as String);
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(
      File file, String coverId, Uint8List jpeg, int gen) async {
    try {
      final sealed = await Aead.encrypt(
        version: kVerAesGcm,
        key: _cacheKey,
        plaintext: Uint8List.fromList(utf8
            .encode(jsonEncode({'id': coverId, 'jpeg': base64.encode(jpeg)}))),
        aad: _aad,
      );
      if (gen != _gen) return;
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(sealed, flush: true);
      if (gen != _gen) {
        await _delete(tmp);
        return;
      }
      await tmp.rename(file.path);
    } catch (_) {
      // The next session fetches it again
    }
  }

  Future<File> _fileFor(String albumId) async =>
      File(p.join(_root.path, await _hash('album:$albumId')));

  static Future<String> _hash(String s) async {
    final h = await cg.Sha256().hash(utf8.encode('miuchio.cover-cache:$s'));
    return base64Url.encode(h.bytes).replaceAll('=', '');
  }

  static Future<void> _delete(FileSystemEntity e) async {
    try {
      if (await e.exists()) await e.delete(recursive: true);
    } catch (_) {}
  }
}
