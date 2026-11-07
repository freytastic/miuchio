import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/data/models/album_model.dart';
import 'package:miuchio/data/storage/safety_store.dart';

Uint8List _key([int fill = 0x11]) =>
    Uint8List.fromList(List<int>.filled(32, fill));

AlbumModel _album(String id, {int joins = 1}) => AlbumModel(
    id: id,
    nameCt: null,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    joins: joins);

void main() {
  late Directory tmp;
  late File file;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('safety_');
    file = File('${tmp.path}/miuchio_safety.kec');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<SafetyStore> open([int fill = 0x11]) =>
      SafetyStore.open(file: file, cacheRootKey: _key(fill));

  test('an accepted album and a block name survive a restart', () async {
    final store = await open();
    await store.accept(_album('a'));
    await store.rememberBlock('b1', 'Sara');
    await store.flush();

    final reopened = await open();
    expect(reopened.accepted('a'), isTrue);
    expect(reopened.blockedName('b1'), 'Sara');
  });

  test('leaving an album asks again on the next invite', () async {
    final store = await open();
    await store.accept(_album('a'));
    await store.forget('a');
    expect(store.accepted('a'), isFalse);
    expect(store.holdsAlbum('a'), isFalse);
  });

  test('a re-add this phone never saw asks again', () async {
    final store = await open();
    await store.accept(_album('a'));
    store.reconcile([_album('a')]);
    expect(store.accepted('a'), isTrue);

    store.reconcile([_album('a', joins: 2)]);
    expect(store.accepted('a'), isFalse);
  });

  test('a file under another key gates every album again', () async {
    final store = await open();
    await store.accept(_album('a'));
    await store.flush();

    final other = await open(0x22);
    expect(other.accepted('a'), isFalse);
  });

  test('the file on disk is sealed, not plaintext json', () async {
    final store = await open();
    await store.rememberBlock('b1', 'Sara');
    await store.accept(_album('album-one'));
    await store.flush();

    final raw = String.fromCharCodes(await file.readAsBytes());
    expect(raw.contains('album-one'), isFalse);
    expect(raw.contains('Sara'), isFalse);
  });
}
