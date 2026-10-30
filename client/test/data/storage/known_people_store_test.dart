import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/data/storage/known_people_store.dart';

import '../../_sodium_setup.dart';

void main() {
  late Directory dir;
  final key = Uint8List.fromList(List.filled(32, 9));

  setUpAll(() async => ensureSodium());

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('miuchio_known');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  File file() => File('${dir.path}/known.kec');

  Uint8List ik(int b) => Uint8List.fromList(List.filled(32, b));

  test('remembered people survive a restart, newest first', () async {
    final s = await KnownPeopleStore.open(file: file(), cacheRootKey: key);
    await s.remember(
        handle: 'ABCD2345',
        ikPub: ik(1),
        albumId: 'a',
        memberToken: 't1',
        at: DateTime(2026, 1, 1));
    await s.remember(
        handle: 'WXYZ6789',
        ikPub: ik(2),
        albumId: 'b',
        memberToken: 't2',
        at: DateTime(2026, 2, 1));

    final again = await KnownPeopleStore.open(file: file(), cacheRootKey: key);

    expect([for (final p in again.people) p.handle], ['WXYZ6789', 'ABCD2345']);
  });

  test('one person is one entry, however often invited', () async {
    final s = await KnownPeopleStore.open(file: file(), cacheRootKey: key);
    await s.remember(
        handle: 'ABCD2345', ikPub: ik(1), albumId: 'a', memberToken: 't1');
    await s.remember(
        handle: 'ABCD2345', ikPub: ik(1), albumId: 'b', memberToken: 't2');

    expect(s.people, hasLength(1));
    expect(s.people.single.albumId, 'b');
  });

  test('the file is sealed and opens under no other key', () async {
    final s = await KnownPeopleStore.open(file: file(), cacheRootKey: key);
    await s.remember(
        handle: 'ABCD2345', ikPub: ik(1), albumId: 'a', memberToken: 't1');

    final raw = await file().readAsBytes();
    expect(String.fromCharCodes(raw).contains('ABCD2345'), isFalse);

    final other = await KnownPeopleStore.open(
        file: file(), cacheRootKey: Uint8List.fromList(List.filled(32, 1)));
    expect(other.people, isEmpty);
  });

  test('clearing forgets everyone and the file', () async {
    final s = await KnownPeopleStore.open(file: file(), cacheRootKey: key);
    await s.remember(
        handle: 'ABCD2345', ikPub: ik(1), albumId: 'a', memberToken: 't1');

    await s.clear();

    expect(s.people, isEmpty);
    expect(file().existsSync(), isFalse);
  });
}
