import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:miuchio/crypto/primitives.dart';
import 'package:miuchio/crypto/wire_format.dart';
import 'debug_log_allowlist.dart';

enum DebugLevel { info, warn, error }

enum DebugEvent {
  appStart('app.start', DebugLevel.info),
  appError('app.error', DebugLevel.error),
  uploadQueued('upload.queued', DebugLevel.info),
  uploadRetrying('upload.retrying', DebugLevel.warn),
  uploadPaused('upload.paused', DebugLevel.warn),
  uploadRecovered('upload.recovered', DebugLevel.info),
  uploadFailed('upload.failed', DebugLevel.error),
  downloadFailed('download.failed', DebugLevel.error),
  requestFailed('request.failed', DebugLevel.warn),
  liveConnected('live.connected', DebugLevel.info),
  liveDropped('live.dropped', DebugLevel.warn),
  keystoreFailed('keystore.failed', DebugLevel.error),
  albumBlocked('album.blocked', DebugLevel.error);

  final String code;
  final DebugLevel level;

  const DebugEvent(this.code, this.level);

  static DebugEvent? byCode(String code) {
    for (final e in values) {
      if (e.code == code) return e;
    }
    return null;
  }
}

class DebugEntry {
  final DebugEvent event;
  final DateTime first;
  DateTime last;
  int count;
  final String? reason;
  final String? stage;
  final String? route;
  String? op;
  int? attempt;
  final int? ms;
  final String? version;

  DebugEntry._({
    required this.event,
    required this.first,
    required this.last,
    required this.count,
    this.reason,
    this.stage,
    this.route,
    this.op,
    this.attempt,
    this.ms,
    this.version,
  });

  DebugLevel get level => event.level;

  // Rows sharing a topic describe one operation or one connection, so only
  // the newest row of a topic may absorb a repeat
  String get _topic {
    if (op != null) return 'op:$op';
    if (event == DebugEvent.liveConnected || event == DebugEvent.liveDropped) {
      return 'live';
    }
    return '${event.code}|$reason|$stage|$route|$version';
  }

  bool _sameKind(DebugEntry o) =>
      o.event == event &&
      o.reason == reason &&
      o.stage == stage &&
      o.route == route &&
      o.op == op &&
      o.version == version;

  Map<String, Object> toJson() => {
        'e': event.code,
        't': first.millisecondsSinceEpoch,
        if (count > 1) 'l': last.millisecondsSinceEpoch,
        if (count > 1) 'n': count,
        if (reason != null) 'r': reason!,
        if (stage != null) 's': stage!,
        if (route != null) 'p': route!,
        if (op != null) 'o': op!,
        if (attempt != null) 'a': attempt!,
        if (ms != null) 'd': ms!,
        if (version != null) 'v': version!,
      };

  // Decoded fields pass the same allowlist as live ones
  static DebugEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final event = DebugEvent.byCode(raw['e'] as String? ?? '');
    final t = raw['t'];
    if (event == null || t is! int) return null;
    final first = DateTime.fromMillisecondsSinceEpoch(t);
    final l = raw['l'];
    final n = raw['n'];
    return DebugEntry._(
      event: event,
      first: first,
      last: l is int ? DateTime.fromMillisecondsSinceEpoch(l) : first,
      count: n is int && n > 0 ? n : 1,
      reason: DebugLogAllowlist.reason(raw['r'] as String?),
      stage: DebugLogAllowlist.stage(raw['s'] as String?),
      route: DebugLogAllowlist.route(raw['p'] as String?),
      op: DebugLogAllowlist.op(raw['o'] as String?),
      attempt: DebugLogAllowlist.count(raw['a']),
      ms: DebugLogAllowlist.count(raw['d']),
      version: DebugLogAllowlist.version(raw['v'] as String?),
    );
  }
}

// Entry metadata is filtered by DebugLogAllowlist before it reaches memory
abstract class DebugLog {
  static const int maxEntries = 500;
  static const Duration maxAge = Duration(days: 7);
  static const int maxBytes = 256 * 1024;
  static const Duration mergeWindow = Duration(minutes: 10);
  static const String fileName = 'miuchio_debug.kec';

  static final Uint8List _aad =
      Uint8List.fromList('miuchio.debug-log-v1'.codeUnits);

  static final List<DebugEntry> _entries = [];
  static final Map<String, String> _ops = {};
  // Random per process so handles from earlier sessions on disk cannot
  // collide with this one, the counter keeps handles unique within it
  static final String _session =
      Random.secure().nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
  static int _opSeq = 0;

  // Bumped after a record lands, never synchronously inside record()
  static final ValueNotifier<int> changes = ValueNotifier(0);
  static bool _notifyQueued = false;

  static DateTime Function() _now = DateTime.now;
  static File? _file;
  static Uint8List? _key;
  static Timer? _flushTimer;
  // Invalidates queued writes and loads when clear races them
  static int _gen = 0;
  static Future<void> _inFlight = Future.value();

  @visibleForTesting
  static set debugNow(DateTime Function()? now) => _now = now ?? DateTime.now;

  // Forgets memory and the key but leaves the file, like a process restart
  @visibleForTesting
  static Future<void> debugReset() async {
    _gen++;
    _flushTimer?.cancel();
    try {
      await _inFlight;
    } catch (_) {}
    _entries.clear();
    _ops.clear();
    _key = null;
    _file = null;
    _now = DateTime.now;
  }

  static List<DebugEntry> get entries => List.unmodifiable(_entries);

  // Records app start once the version is known, buffering until attach
  static void start() {
    unawaited(PackageInfo.fromPlatform().then((info) {
      record(DebugEvent.appStart,
          version: '${info.version}+${info.buildNumber}');
    }, onError: (_) {
      record(DebugEvent.appStart);
    }));
  }

  // Logging must never break the operation it describes
  static void record(
    DebugEvent event, {
    String? reason,
    String? stage,
    String? route,
    String? op,
    int? attempt,
    int? ms,
    String? version,
  }) {
    try {
      final now = _now();
      final entry = DebugEntry._(
        event: event,
        first: now,
        last: now,
        count: 1,
        reason: DebugLogAllowlist.reason(reason),
        stage: DebugLogAllowlist.stage(stage),
        route: DebugLogAllowlist.route(route),
        op: DebugLogAllowlist.op(op),
        attempt: DebugLogAllowlist.count(attempt),
        ms: DebugLogAllowlist.count(ms),
        version: DebugLogAllowlist.version(version),
      );
      if (!_merge(entry)) _entries.add(entry);
      _prune();
      _scheduleFlush(event.level == DebugLevel.error
          ? const Duration(milliseconds: 500)
          : const Duration(seconds: 3));
      _notify();
    } catch (_) {}
  }

  // A retry loop folds into one row instead of evicting older history
  // The merged row moves to the end so rows stay ordered by their last time
  static bool _merge(DebugEntry e) {
    final topic = e._topic;
    final floor = max(0, _entries.length - 32);
    for (var i = _entries.length - 1; i >= floor; i--) {
      final o = _entries[i];
      if (o._topic != topic) continue;
      if (!o._sameKind(e) || e.last.difference(o.last) > mergeWindow) {
        return false;
      }
      o.count++;
      o.last = e.last;
      if (e.attempt != null && (o.attempt ?? 0) < e.attempt!) {
        o.attempt = e.attempt;
      }
      if (i != _entries.length - 1) _entries.add(_entries.removeAt(i));
      return true;
    }
    return false;
  }

  // Handle linking events of one operation without the underlying ID, which
  // never leaves this map
  static String op(String key) {
    final hit = _ops[key];
    if (hit != null) return hit;
    if (_ops.length >= 256) _ops.remove(_ops.keys.first);
    return _ops[key] = '$_session.${++_opSeq}';
  }

  static void _prune() {
    final floor = _now().subtract(maxAge);
    _entries.removeWhere((e) => e.last.isBefore(floor));
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
  }

  static void _notify() {
    if (_notifyQueued) return;
    _notifyQueued = true;
    // Deferred so an error raised during build cannot rebuild the log page
    // inside that same build
    Timer.run(() {
      _notifyQueued = false;
      changes.value++;
    });
  }

  // Entries recorded before the key loads stay in memory and are written
  // after the older entries already on disk
  // The load runs in the same queue as writes and clear, so a clear during
  // the load still finds the file and logging keeps saving afterwards
  static Future<void> attach(Uint8List cacheRootKey, {File? file}) {
    _key = cacheRootKey;
    final gen = _gen;
    final load = _inFlight.then((_) => _load(file, cacheRootKey, gen));
    _inFlight = load;
    return load;
  }

  static Future<void> _load(File? file, Uint8List key, int gen) async {
    try {
      final f = file ??
          File(p.join((await getApplicationSupportDirectory()).path, fileName));
      _file = f;
      final older = await _read(f, key);
      // A clear that queued behind this load deletes these entries
      if (gen == _gen) {
        _entries.insertAll(0, older);
        _prune();
        _notify();
      }
      _scheduleFlush(const Duration(seconds: 1));
    } catch (_) {}
  }

  static Future<List<DebugEntry>> _read(File f, Uint8List key) async {
    try {
      if (!await f.exists()) return const [];
      final wire = await f.readAsBytes();
      final pt = await Aead.decrypt(wire: wire, key: key, aad: _aad);
      final json = jsonDecode(utf8.decode(pt));
      if (json is! Map || json['e'] is! List) return const [];
      return (json['e'] as List)
          .map(DebugEntry.fromJson)
          .whereType<DebugEntry>()
          .toList();
    } catch (_) {
      // Corrupt or foreign files start an empty log
      return const [];
    }
  }

  static void _scheduleFlush(Duration delay) {
    if (_key == null) return;
    final pending = _flushTimer;
    if (pending != null && pending.isActive) return;
    _flushTimer = Timer(delay, () => unawaited(flush()));
  }

  static Future<void> flush() {
    _flushTimer?.cancel();
    if (_key == null) return _inFlight;
    final gen = _gen;
    _inFlight = _inFlight.then((_) => _write(gen));
    return _inFlight;
  }

  static Future<void> _write(int gen) async {
    final key = _key;
    final file = _file;
    if (gen != _gen || key == null || file == null) return;
    try {
      var body = _encode();
      // Oldest entries go first when the byte budget runs out
      while (body.length > maxBytes && _entries.isNotEmpty) {
        _entries.removeRange(0, max(1, _entries.length ~/ 10));
        body = _encode();
      }
      final sealed = await Aead.encrypt(
          version: kVerAesGcm, key: key, plaintext: body, aad: _aad);
      if (gen != _gen) return;
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(sealed, flush: true);
      if (gen != _gen) {
        await _delete(tmp);
        return;
      }
      await tmp.rename(file.path);
    } catch (_) {}
  }

  static Uint8List _encode() => Uint8List.fromList(utf8.encode(jsonEncode({
        'v': 1,
        'e': [for (final e in _entries) e.toJson()],
      })));

  // Deletes inside the write queue, after any load or write already queued
  // and before any write recorded later
  static Future<void> clear() {
    _gen++;
    _flushTimer?.cancel();
    _entries.clear();
    _ops.clear();
    _notify();
    final done = _inFlight.then((_) async {
      final file = _file;
      if (file == null) return;
      await _delete(file);
      await _delete(File('${file.path}.tmp'));
    });
    _inFlight = done;
    return done;
  }

  // Account wipe drops the key reference before the key bytes are zeroed
  static Future<void> shutdown() async {
    _key = null;
    await clear();
    _file = null;
  }

  static Future<void> _delete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
