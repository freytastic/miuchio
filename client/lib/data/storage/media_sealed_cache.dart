import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'package:miuchio/crypto/primitives.dart';
import 'package:miuchio/crypto/wire_format.dart';
import 'package:miuchio/data/models/album_model.dart';
import 'package:miuchio/domain/albums/album_cleanup.dart';
import 'package:miuchio/e2ee/media_record.dart';

import 'media_cache_key.dart';
import 'media_catalog.dart';

// Seals cached plaintext to its media and asset slot under the device cache key

const String _formatSentinel = 'format_v3';

const String _createAlbums = '''
  CREATE TABLE albums (
    album_id   TEXT PRIMARY KEY,
    album_json TEXT NOT NULL,
    sort_index INTEGER NOT NULL
  )
''';

// Albums whose local data must still be wiped, kept until a wipe finishes
const String _createAlbumCleanup = '''
  CREATE TABLE album_cleanup (
    album_id  TEXT PRIMARY KEY,
    confirmed INTEGER NOT NULL,
    version   INTEGER NOT NULL DEFAULT 0
  )
''';

// Pins visible shelf thumbnails during eviction
const String _createCovers = '''
  CREATE TABLE album_covers (
    album_id TEXT NOT NULL,
    media_id TEXT NOT NULL,
    slot     INTEGER NOT NULL,
    PRIMARY KEY (album_id, slot)
  )
''';

// Server confirmed deletions. Unlike invalidate, which only frees space, no
// later write can restore these, even after a restart. Media IDs are never
// reused, so a mark cannot hide a real photo
const String _createDeletedMedia = '''
  CREATE TABLE deleted_media (
    media_id   TEXT PRIMARY KEY,
    album_id   TEXT NOT NULL,
    deleted_at INTEGER NOT NULL
  )
''';

// Any listing or download that could carry a deleted photo is long finished
const Duration _deletedMarkLifetime = Duration(days: 30);

const String _notDeleted =
    'NOT EXISTS (SELECT 1 FROM deleted_media WHERE media_id = ?)';

class MediaSealedCache
    implements MediaCatalog, AlbumCatalog, AlbumCleanupStore {
  // Full photos are disposable while the database and thumbnails are durable
  final Directory _root;
  final Directory _durableRoot;
  final Database _db;
  final Uint8List _cacheKey;
  // Full photos and thumbnails have independent eviction budgets
  final int budgetBytes;
  final int durableBudgetBytes;

  MediaSealedCache._(this._root, this._durableRoot, this._db, this._cacheKey,
      this.budgetBytes, this.durableBudgetBytes);

  static Future<MediaSealedCache> open({
    Directory? rootDir,
    Directory? durableDir,
    required Uint8List cacheRootKey,
    int budgetBytes = 1024 * 1024 * 1024,
    int durableBudgetBytes = 512 * 1024 * 1024,
    // Tests move the clock to expire deletion marks
    DateTime Function() now = DateTime.now,
  }) async {
    // getApplicationCacheDirectory : Android app cache dir (covered by
    // allowBackup="false" in the manifest) / iOS Library/Caches (excluded from
    // iCloud backup by OS default). Sealed blobs never reach cloud backup
    final root = rootDir ??
        Directory(p.join(
            (await getApplicationCacheDirectory()).path, 'miuchio_media'));
    if (!root.existsSync()) root.createSync(recursive: true);
    // prepareInstall excludes Application Support from iOS backup
    // Tests passing only rootDir keep the legacy single root layout
    final durable = durableDir ??
        (rootDir ??
            Directory(p.join((await getApplicationSupportDirectory()).path,
                'miuchio_vault')));
    if (!durable.existsSync()) durable.createSync(recursive: true);
    final db = await openDatabase(
      p.join(durable.path, 'records.db'),
      version: 7,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE media_records (
            media_id    TEXT PRIMARY KEY,
            album_id    TEXT NOT NULL,
            record_json TEXT NOT NULL,
            blob_bytes  INTEGER NOT NULL DEFAULT 0,
            thumb_bytes INTEGER NOT NULL DEFAULT 0,
            last_access INTEGER NOT NULL,
            sort_index  INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_records_album ON media_records(album_id)');
        await db.execute(
            'CREATE INDEX idx_records_access ON media_records(last_access)');
        await db.execute(_createCovers);
        await db.execute(_createAlbums);
        await db.execute(_createAlbumCleanup);
        await db.execute(_createDeletedMedia);
      },
      onUpgrade: (db, from, to) async {
        if (from < 2) await db.execute(_createCovers);
        // created_at is only hour precise, so persist explicit server order
        if (from < 3) {
          await db.execute('ALTER TABLE media_records '
              'ADD COLUMN sort_index INTEGER NOT NULL DEFAULT 0');
        }
        if (from < 4) await db.execute(_createAlbums);
        if (from < 5) await db.execute(_createAlbumCleanup);
        if (from == 5) {
          await db.execute('ALTER TABLE album_cleanup '
              'ADD COLUMN version INTEGER NOT NULL DEFAULT 0');
        }
        if (from < 7) await db.execute(_createDeletedMedia);
      },
    );
    final cache = MediaSealedCache._(
        root, durable, db, cacheRootKey, budgetBytes, durableBudgetBytes);
    await cache._migrateIfNeeded();
    await cache._sweepDeleted(now());
    return cache;
  }

  Future<void> close() => _db.close();

  @override
  Future<List<AlbumModel>> loadAlbums() async {
    final rows = await _db.query('albums',
        columns: ['album_json'], orderBy: 'sort_index ASC');
    final out = <AlbumModel>[];
    for (final row in rows) {
      try {
        out.add(AlbumModel.fromJson(
            jsonDecode(row['album_json'] as String) as Map<String, dynamic>));
      } catch (_) {
        // One unreadable row must not cost the whole shelf
      }
    }
    return out;
  }

  @override
  Future<Map<String, CleanupRecord>> pending() async {
    final rows = await _db.query('album_cleanup');
    return {
      for (final r in rows)
        r['album_id'] as String: (
          confirmed: (r['confirmed'] as int) != 0,
          version: r['version'] as int,
        ),
    };
  }

  // Avoids UPSERT, which older Android SQLite lacks
  @override
  Future<void> put(String albumId, {required bool confirmed}) async {
    await _db.transaction((txn) async {
      await txn.rawInsert(
        'INSERT OR IGNORE INTO album_cleanup (album_id, confirmed, version) '
        'VALUES (?, 0, -1)',
        [albumId],
      );
      await txn.rawUpdate(
        'UPDATE album_cleanup SET confirmed = MAX(confirmed, ?), '
        'version = version + 1 WHERE album_id = ?',
        [confirmed ? 1 : 0, albumId],
      );
    });
  }

  @override
  Future<void> removeIfUnchanged(String albumId, int version) async {
    await _db.delete('album_cleanup',
        where: 'album_id = ? AND version = ?', whereArgs: [albumId, version]);
  }

  @override
  Future<void> dropAlbum(String albumId) async {
    await _db.delete('albums', where: 'album_id = ?', whereArgs: [albumId]);
  }

  @override
  Future<void> saveAlbums(List<AlbumModel> albums) async {
    await _db.transaction((txn) async {
      await txn.delete('albums');
      for (var i = 0; i < albums.length; i++) {
        await txn.insert('albums', {
          'album_id': albums[i].id,
          'album_json': jsonEncode(albums[i].toJson()),
          'sort_index': i,
        });
      }
    });
  }

  // Older layouts are wiped rather than read, which also recovers from a lost
  // key sentinel
  Future<void> _migrateIfNeeded() async {
    final sentinel = File(p.join(_durableRoot.path, _formatSentinel));
    if (sentinel.existsSync()) return;
    await _db.delete('media_records');
    await _db.delete('album_covers');
    for (final dir in {_root.path, _durableRoot.path}) {
      final d = Directory(dir);
      if (!d.existsSync()) continue;
      for (final e in d.listSync()) {
        if (e is File && _isBlobFile(e.path)) e.deleteSync();
      }
    }
    sentinel.writeAsStringSync('3');
  }

  static bool _isBlobFile(String path) =>
      path.endsWith('.kec') || path.endsWith('.bin') || path.endsWith('.tmp');

  Uint8List _aad(MediaCacheKey k) => Uint8List.fromList(
        utf8.encode(k.mediaId) +
            utf8.encode(k.asset == CacheAsset.thumb ? 'thumb' : 'file'),
      );

  // Thumbnails stay durable for offline rendering
  Directory _rootFor(CacheAsset asset) =>
      asset == CacheAsset.thumb ? _durableRoot : _root;

  File _blobFile(MediaCacheKey k) =>
      File(p.join(_rootFor(k.asset).path, k.diskFilename));

  Future<MediaRecord?> readRecord(String mediaId) async {
    final rows = await _db.query('media_records',
        columns: ['record_json'],
        where: 'media_id = ?',
        whereArgs: [mediaId],
        limit: 1);
    if (rows.isEmpty) return null;
    // A bytes only placeholder is not a complete record
    final raw = rows.first['record_json'] as String;
    if (raw.length <= 2) return null;
    try {
      return MediaRecord.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  // Ignore byte accounting placeholders without render metadata
  @override
  Future<List<MediaRecord>> listRecordsForAlbum(String albumId) async {
    final rows = await _db.query('media_records',
        columns: ['record_json'],
        where: 'album_id = ? AND length(record_json) > 2',
        whereArgs: [albumId],
        orderBy: 'sort_index ASC');
    final out = <MediaRecord>[];
    for (final row in rows) {
      try {
        out.add(MediaRecord.fromJson(
            jsonDecode(row['record_json'] as String) as Map<String, dynamic>));
      } catch (_) {
        // Keep one corrupt row from hiding the rest of the album
      }
    }
    return out;
  }

  @override
  Future<void> reconcileAlbum(String albumId, List<MediaRecord> records) async {
    final keep = {for (final r in records) r.id};
    final existing = await _db.query('media_records',
        columns: ['media_id'], where: 'album_id = ?', whereArgs: [albumId]);

    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      for (var i = 0; i < records.length; i++) {
        final r = records[i];
        final json = jsonEncode(r.toJson());
        await txn.rawInsert(
          'INSERT OR IGNORE INTO media_records '
          '(media_id, album_id, record_json, last_access, sort_index) '
          'SELECT ?, ?, ?, ?, ? WHERE $_notDeleted',
          [r.id, albumId, json, now, i, r.id],
        );
        // A listing is not a view, so it must not refresh the LRU timestamp
        await txn.rawUpdate(
          'UPDATE media_records SET album_id = ?, record_json = ?, '
          'sort_index = ? WHERE media_id = ?',
          [albumId, json, i, r.id],
        );
      }
    });

    for (final row in existing) {
      final id = row['media_id'] as String;
      if (!keep.contains(id)) await invalidate(id);
    }
  }

  // Preserve byte accounting without REPLACE or API 30 only UPSERT syntax
  Future<void> writeRecord(MediaRecord r) async {
    final json = jsonEncode(r.toJson());
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      // New arrivals stay first until the next server reconciliation
      await txn.rawInsert(
        'INSERT OR IGNORE INTO media_records '
        '(media_id, album_id, record_json, last_access, sort_index) '
        'SELECT ?, ?, ?, ?, '
        'COALESCE((SELECT MIN(sort_index) - 1 FROM media_records '
        'WHERE album_id = ?), -1) WHERE $_notDeleted',
        [r.id, r.albumId, json, now, r.albumId, r.id],
      );
      await txn.rawUpdate(
        'UPDATE media_records SET album_id = ?, record_json = ?, '
        'last_access = ? WHERE media_id = ?',
        [r.albumId, json, now, r.id],
      );
    });
  }

  // Preview records may fill placeholders but never overwrite full records
  Future<void> writeRecordIfAbsent(MediaRecord r) async {
    final json = jsonEncode(r.toJson());
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      // Put new previews first, including when filling a placeholder row
      await txn.rawInsert(
        'INSERT OR IGNORE INTO media_records '
        '(media_id, album_id, record_json, last_access, sort_index) '
        'SELECT ?, ?, ?, ?, '
        'COALESCE((SELECT MIN(sort_index) - 1 FROM media_records '
        'WHERE album_id = ?), -1) WHERE $_notDeleted',
        [r.id, r.albumId, json, now, r.albumId, r.id],
      );
      await txn.rawUpdate(
        "UPDATE media_records SET record_json = ?, last_access = ?, "
        "sort_index = COALESCE("
        "(SELECT MIN(sort_index) - 1 FROM media_records WHERE album_id = ?), -1) "
        "WHERE media_id = ? AND record_json = '{}'",
        [json, now, r.albumId, r.id],
      );
    });
  }

  Future<Uint8List?> readBlob(MediaCacheKey k) async {
    final f = _blobFile(k);
    if (!f.existsSync()) return null;
    Uint8List wire;
    try {
      wire = await f.readAsBytes();
    } catch (_) {
      return null;
    }
    try {
      final pt = await Aead.decrypt(wire: wire, key: _cacheKey, aad: _aad(k));
      await _db.update('media_records',
          {'last_access': DateTime.now().millisecondsSinceEpoch},
          where: 'media_id = ?', whereArgs: [k.mediaId]);
      return pt;
    } on AeadAuthFailed {
      // Tampered or sealed under another key, purge and miss
      await invalidate(k.mediaId);
      return null;
    } on FormatException {
      await invalidate(k.mediaId);
      return null;
    }
  }

  Future<void> writeBlob(MediaCacheKey k, Uint8List plaintext) async {
    final sealed = await Aead.encrypt(
        version: kVerAesGcm,
        key: _cacheKey,
        plaintext: plaintext,
        aad: _aad(k));
    final f = _blobFile(k);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(sealed, flush: true);
    await tmp.rename(f.path);
    final col = k.asset == CacheAsset.thumb ? 'thumb_bytes' : 'blob_bytes';
    final now = DateTime.now().millisecondsSinceEpoch;
    // Atomically create the row and update its asset size
    final deleted = await _db.transaction((txn) async {
      final gone = await txn.rawQuery(
          'SELECT 1 FROM deleted_media WHERE media_id = ?', [k.mediaId]);
      if (gone.isNotEmpty) return true;
      await txn.rawInsert(
        'INSERT OR IGNORE INTO media_records '
        "(media_id, album_id, record_json, last_access) VALUES (?, ?, '{}', ?)",
        [k.mediaId, k.albumId, now],
      );
      await txn.rawUpdate(
        'UPDATE media_records SET $col = ?, last_access = ? WHERE media_id = ?',
        [sealed.length, now, k.mediaId],
      );
      return false;
    });
    // A download that lands after the delete removes its own file. The mark
    // commits before markDeleted removes files, so one of the two catches it
    if (deleted) {
      if (f.existsSync()) f.deleteSync();
      return;
    }
    await _evictIfOverBudget();
  }

  // Photo pressure must not evict thumbnails
  Future<void> _evictIfOverBudget() async {
    await _evictDisposable();
    await _evictDurable();
    // Keep metadata only rows so albums remain available offline
    await _db.delete('media_records',
        where:
            'blob_bytes = 0 AND thumb_bytes = 0 AND length(record_json) <= 2');
  }

  Future<void> _evictDisposable() async {
    var total = await _sumOf('blob_bytes');
    if (total <= budgetBytes) return;
    final rows = await _db.query('media_records',
        columns: ['media_id', 'blob_bytes'], orderBy: 'last_access ASC');
    for (final row in rows) {
      if (total <= budgetBytes) break;
      final bytes = row['blob_bytes'] as int;
      if (bytes == 0) continue;
      await _dropAsset(row['media_id'] as String, CacheAsset.file);
      total -= bytes;
    }
  }

  Future<void> _evictDurable() async {
    var total = await _sumOf('thumb_bytes');
    if (total <= durableBudgetBytes) return;
    final pinned = await _pinnedMediaIds();
    final rows = await _db.query('media_records',
        columns: ['media_id', 'thumb_bytes'], orderBy: 'last_access ASC');
    for (final row in rows) {
      if (total <= durableBudgetBytes) break;
      final id = row['media_id'] as String;
      if (pinned.contains(id)) continue;
      final bytes = row['thumb_bytes'] as int;
      if (bytes == 0) continue;
      await _dropAsset(id, CacheAsset.thumb);
      total -= bytes;
    }
  }

  Future<int> _sumOf(String column) async {
    final rows = await _db
        .rawQuery('SELECT COALESCE(SUM($column), 0) AS t FROM media_records');
    return rows.first['t'] as int;
  }

  Future<Set<String>> _pinnedMediaIds() async {
    final rows = await _db.query('album_covers', columns: ['media_id']);
    return {for (final r in rows) r['media_id'] as String};
  }

  Future<void> _dropAsset(String mediaId, CacheAsset asset) async {
    final name =
        asset == CacheAsset.thumb ? '$mediaId.thumb.kec' : '$mediaId.kec';
    final f = File(p.join(_rootFor(asset).path, name));
    if (f.existsSync()) f.deleteSync();
    final col = asset == CacheAsset.thumb ? 'thumb_bytes' : 'blob_bytes';
    await _db.update('media_records', {col: 0},
        where: 'media_id = ?', whereArgs: [mediaId]);
  }

  // Replace a cover registry atomically to prevent stale interleaving
  Future<void> setCovers(String albumId, List<String> mediaIds) async {
    await _db.transaction((txn) async {
      await txn
          .delete('album_covers', where: 'album_id = ?', whereArgs: [albumId]);
      for (var i = 0; i < mediaIds.length && i < 3; i++) {
        await txn.rawInsert(
          'INSERT OR REPLACE INTO album_covers (album_id, media_id, slot) '
          'SELECT ?, ?, ? WHERE $_notDeleted',
          [albumId, mediaIds[i], i, mediaIds[i]],
        );
      }
    });
  }

  Future<List<String>> coversFor(String albumId) async {
    final rows = await _db.query('album_covers',
        columns: ['media_id'],
        where: 'album_id = ?',
        whereArgs: [albumId],
        orderBy: 'slot ASC');
    return [for (final r in rows) r['media_id'] as String];
  }

  // Files go first: a failed delete then leaves the record behind, which keeps
  // the blob findable for the next attempt
  Future<void> invalidate(String mediaId) async {
    _deleteFiles(mediaId);
    await _db
        .delete('media_records', where: 'media_id = ?', whereArgs: [mediaId]);
    await _db
        .delete('album_covers', where: 'media_id = ?', whereArgs: [mediaId]);
  }

  // Throws only when the mark did not save. A file that fails to delete here
  // is left to the sweep on the next open
  Future<void> markDeleted(String albumId, String mediaId) async {
    await _db.transaction((txn) async {
      await txn.rawInsert(
        'INSERT OR IGNORE INTO deleted_media (media_id, album_id, deleted_at) '
        'VALUES (?, ?, ?)',
        [mediaId, albumId, DateTime.now().millisecondsSinceEpoch],
      );
      await txn
          .delete('media_records', where: 'media_id = ?', whereArgs: [mediaId]);
      await txn
          .delete('album_covers', where: 'media_id = ?', whereArgs: [mediaId]);
    });
    try {
      _deleteFiles(mediaId);
    } catch (_) {}
  }

  // Includes the temp file an interrupted writeBlob leaves behind
  void _deleteFiles(String mediaId) {
    for (final asset in CacheAsset.values) {
      final name =
          asset == CacheAsset.thumb ? '$mediaId.thumb.kec' : '$mediaId.kec';
      final f = File(p.join(_rootFor(asset).path, name));
      if (f.existsSync()) f.deleteSync();
      final tmp = File('${f.path}.tmp');
      if (tmp.existsSync()) tmp.deleteSync();
    }
  }

  // Finishes interrupted file deletes. A mark expires only after its files
  // are gone, however long the app stayed closed
  Future<void> _sweepDeleted(DateTime now) async {
    final cutoff = now.subtract(_deletedMarkLifetime).millisecondsSinceEpoch;
    try {
      final rows =
          await _db.query('deleted_media', columns: ['media_id', 'deleted_at']);
      final expired = <String>[];
      for (final r in rows) {
        final id = r['media_id'] as String;
        try {
          _deleteFiles(id);
        } catch (_) {
          continue;
        }
        if ((r['deleted_at'] as int) < cutoff) expired.add(id);
      }
      if (expired.isEmpty) return;
      final batch = _db.batch();
      for (final id in expired) {
        batch.delete('deleted_media', where: 'media_id = ?', whereArgs: [id]);
      }
      await batch.commit(noResult: true);
    } catch (_) {
      // The next open tries again
    }
  }

  Future<void> clearAlbum(String albumId) async {
    final rows = await _db.query('media_records',
        columns: ['media_id'], where: 'album_id = ?', whereArgs: [albumId]);
    for (final r in rows) {
      await invalidate(r['media_id'] as String);
    }
    await _db
        .delete('album_covers', where: 'album_id = ?', whereArgs: [albumId]);
  }

  Future<void> clearAll() async {
    await _db.delete('media_records');
    await _db.delete('album_covers');
    await _db.delete('deleted_media');
    // Clear both roots so durable thumbnails cannot survive deletion
    for (final dir in {_root.path, _durableRoot.path}) {
      final d = Directory(dir);
      if (!d.existsSync()) continue;
      for (final e in d.listSync()) {
        if (e is File && e.path.endsWith('.kec')) e.deleteSync();
      }
    }
  }

  Future<({int thumbs, int full})> usage() async =>
      (thumbs: await _sumOf('thumb_bytes'), full: await _sumOf('blob_bytes'));

  // Thumbnails stay so albums still open offline
  Future<void> clearFull() async {
    final rows = await _db.query('media_records',
        columns: ['media_id'], where: 'blob_bytes > 0');
    for (final row in rows) {
      await _dropAsset(row['media_id'] as String, CacheAsset.file);
    }
  }

  Future<int> totalBytes() async {
    final rows = await _db.rawQuery(
        'SELECT COALESCE(SUM(blob_bytes), 0) + COALESCE(SUM(thumb_bytes), 0) AS t FROM media_records');
    return (rows.first['t'] as int);
  }
}
