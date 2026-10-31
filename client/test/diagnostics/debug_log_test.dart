import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/diagnostics/debug_log.dart';
import 'package:miuchio/diagnostics/debug_log_export.dart';

Uint8List _key(int b) => Uint8List.fromList(List<int>.filled(32, b));

const _device = DeviceSummary(app: '1.0.0 (1)', os: 'Android 14', model: 'x');

void main() {
  late Directory dir;
  late DateTime now;

  setUp(() async {
    await DebugLog.debugReset();
    dir = Directory.systemTemp.createTempSync('debuglog');
    now = DateTime(2026, 10, 12, 9);
    DebugLog.debugNow = () => now;
  });
  tearDown(() async {
    await DebugLog.debugReset();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File logFile() => File('${dir.path}/debug.kec');

  test('values outside the allowlists never reach an entry', () {
    const uuid = '3f2a9c1e-8b7d-4c6a-9e5f-1a2b3c4d5e6f';
    DebugLog.record(DebugEvent.uploadFailed,
        reason: 'Failed host lookup: api.example.com',
        stage: 'https://s3.example.com/bucket/obj?X-Amz-Signature=abc',
        route: '/albums/$uuid/media',
        op: uuid,
        version: 'alice@example.com');
    DebugLog.record(DebugEvent.downloadFailed,
        reason: 'abcdef0123456789abcd', stage: 'user123456789');

    final [a, b] = DebugLog.entries;
    expect(a.reason, 'other');
    expect(a.stage, 'other');
    expect(a.route, '/albums/{id}/media');
    expect(a.op, isNull);
    expect(a.version, isNull);
    expect(b.reason, 'other');
    expect(b.stage, 'other');

    final text = buildDebugLogExport(DebugLog.entries, _device, now: now);
    for (final leak in [
      'example.com',
      'Signature',
      '3f2a9c1e',
      'abcdef0123',
      '123456789',
    ]) {
      expect(text, isNot(contains(leak)));
    }
  });

  test('plausible words such as names are not approved codes', () {
    DebugLog.record(DebugEvent.uploadFailed,
        reason: 'Alice', stage: 'alice', route: '/users/alice/prekey-bundle');
    DebugLog.record(DebugEvent.requestFailed,
        reason: 'E_ALICE', route: '/invite/sunny-beach');
    final [a, b] = DebugLog.entries;
    expect(a.reason, 'other');
    expect(a.stage, 'other');
    expect(a.route, '/users/{id}/prekey-bundle');
    expect(b.reason, 'other');
    expect(b.route, '/invite/{id}');
  });

  test('known codes, templates and random op handles are kept', () {
    final op = DebugLog.op('real-item-id');
    DebugLog.record(DebugEvent.requestFailed,
        reason: 'SocketException_peerreset',
        stage: 'post',
        route: '/albums/{id}/media',
        op: op);
    final e = DebugLog.entries.single;
    expect(e.reason, 'SocketException_peerreset');
    expect(e.route, '/albums/{id}/media');
    expect(e.op, op);
    expect(op, isNot(contains('real')));
    expect(DebugLog.op('real-item-id'), op);
  });

  test('op handles never repeat within a session', () {
    final handles = {for (var i = 0; i < 2000; i++) DebugLog.op('item-$i')};
    expect(handles, hasLength(2000));
  });

  test('failures of different operations stay separate rows', () {
    final a = DebugLog.op('item-a');
    final b = DebugLog.op('item-b');
    DebugLog.record(DebugEvent.uploadFailed, reason: 'transport', op: a);
    DebugLog.record(DebugEvent.uploadFailed, reason: 'transport', op: b);
    DebugLog.record(DebugEvent.uploadFailed, reason: 'transport', op: a);
    expect(DebugLog.entries.map((e) => (e.op, e.count)), [(b, 1), (a, 2)]);
  });

  test('a newer state on a topic is never folded behind an older row', () {
    DebugLog.record(DebugEvent.liveConnected);
    now = now.add(const Duration(seconds: 1));
    DebugLog.record(DebugEvent.liveDropped, reason: 'closed');
    now = now.add(const Duration(seconds: 1));
    DebugLog.record(DebugEvent.liveConnected);
    expect(DebugLog.entries.map((e) => e.event), [
      DebugEvent.liveConnected,
      DebugEvent.liveDropped,
      DebugEvent.liveConnected,
    ]);
  });

  test('an offline loop of two alternating events stays two rows in order',
      () {
    for (var i = 0; i < 20; i++) {
      DebugLog.record(DebugEvent.requestFailed,
          reason: 'SocketException_dns', route: '/ws-ticket');
      DebugLog.record(DebugEvent.liveDropped, reason: 'ApiError');
      now = now.add(const Duration(seconds: 3));
    }
    DebugLog.record(DebugEvent.appError, reason: 'StateError');
    DebugLog.record(DebugEvent.liveDropped, reason: 'ApiError');
    final entries = DebugLog.entries;
    expect(entries.map((e) => e.event), [
      DebugEvent.requestFailed,
      DebugEvent.appError,
      DebugEvent.liveDropped,
    ]);
    expect(entries.last.count, 21);
    for (var i = 1; i < entries.length; i++) {
      expect(entries[i].last.isBefore(entries[i - 1].last), isFalse);
    }
  });

  test('a retry loop folds into one entry within the merge window', () {
    for (var i = 0; i < 12; i++) {
      DebugLog.record(DebugEvent.liveDropped, reason: 'SocketException_dns');
      now = now.add(const Duration(seconds: 3));
    }
    final e = DebugLog.entries.single;
    expect(e.count, 12);
    expect(e.last.isAfter(e.first), isTrue);

    now = now.add(DebugLog.mergeWindow + const Duration(seconds: 1));
    DebugLog.record(DebugEvent.liveDropped, reason: 'SocketException_dns');
    expect(DebugLog.entries, hasLength(2));
  });

  test('keeps at most maxEntries and drops entries older than maxAge', () {
    DebugLog.record(DebugEvent.appStart);
    now = now.add(DebugLog.maxAge + const Duration(minutes: 1));
    for (var i = 0; i < DebugLog.maxEntries + 20; i++) {
      DebugLog.record(DebugEvent.uploadRetrying, reason: 'transport');
      now = now.add(DebugLog.mergeWindow + const Duration(seconds: 1));
    }
    expect(DebugLog.entries, hasLength(DebugLog.maxEntries));
    expect(
        DebugLog.entries.any((e) => e.event == DebugEvent.appStart), isFalse);
  });

  test('entries recorded before attach survive alongside sealed ones',
      () async {
    await DebugLog.attach(_key(3), file: logFile());
    DebugLog.record(DebugEvent.appStart, version: '1.0.0+1');
    await DebugLog.flush();
    expect(logFile().readAsStringSync(encoding: latin1),
        isNot(contains('app.start')));

    await DebugLog.debugReset();
    DebugLog.debugNow = () => now;
    DebugLog.record(DebugEvent.keystoreFailed, reason: 'E_NATIVE');
    await DebugLog.attach(_key(3), file: logFile());
    expect(DebugLog.entries.map((e) => e.event),
        [DebugEvent.appStart, DebugEvent.keystoreFailed]);
  });

  test('clear during the initial load deletes the file and keeps saving',
      () async {
    await DebugLog.attach(_key(8), file: logFile());
    DebugLog.record(DebugEvent.appStart);
    await DebugLog.flush();
    await DebugLog.debugReset();
    DebugLog.debugNow = () => now;

    final load = DebugLog.attach(_key(8), file: logFile());
    final cleared = DebugLog.clear();
    await load;
    await cleared;
    expect(logFile().existsSync(), isFalse);
    expect(DebugLog.entries, isEmpty);

    DebugLog.record(DebugEvent.uploadFailed, reason: 'http_503');
    await DebugLog.flush();
    await DebugLog.debugReset();
    // The reset restores the real clock, which would prune the pinned entry
    DebugLog.debugNow = () => now;
    await DebugLog.attach(_key(8), file: logFile());
    expect(DebugLog.entries.map((e) => e.event), [DebugEvent.uploadFailed]);
  });

  test('a different key starts empty instead of failing', () async {
    await DebugLog.attach(_key(3), file: logFile());
    DebugLog.record(DebugEvent.appStart);
    await DebugLog.flush();
    await DebugLog.debugReset();

    await DebugLog.attach(_key(4), file: logFile());
    expect(DebugLog.entries, isEmpty);
  });

  test('clear removes the file even with a write in flight', () async {
    await DebugLog.attach(_key(5), file: logFile());
    DebugLog.record(DebugEvent.uploadFailed, reason: 'http_503');
    final pending = DebugLog.flush();
    await DebugLog.clear();
    await pending;
    expect(logFile().existsSync(), isFalse);
    expect(File('${logFile().path}.tmp').existsSync(), isFalse);
    expect(DebugLog.entries, isEmpty);
  });

  test('shutdown stops later records from reaching disk', () async {
    await DebugLog.attach(_key(6), file: logFile());
    await DebugLog.shutdown();
    DebugLog.record(DebugEvent.appError, reason: 'StateError');
    await DebugLog.flush();
    expect(logFile().existsSync(), isFalse);
  });
}
