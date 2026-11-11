import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/data/storage/identity_pin_store.dart';
import 'package:miuchio/e2ee/album_authority.dart';
import 'package:miuchio/e2ee/authority_records.dart';

import '../_sodium_setup.dart';
import '_admin_test_helpers.dart';
import '_authority_test_helpers.dart';

class DelayedApi extends FakeAuthorityApi {
  final calls = <Completer<List<SignedHandover>>>[];
  @override
  Future<List<SignedHandover>> fetchHandovers(Uint8List albumId) {
    final c = Completer<List<SignedHandover>>();
    calls.add(c);
    return c.future;
  }
}

class FailSecondWriteFile implements File {
  final File real;
  final String failedPath;
  bool armed = false;
  int pathReads = 0;
  void Function()? afterFirstSnapshot;
  FailSecondWriteFile(this.real, this.failedPath);
  @override
  String get path {
    if (!armed) return real.path;
    final n = ++pathReads;
    if (n == 1) afterFirstSnapshot?.call();
    return n >= 3 ? failedPath : real.path;
  }

  @override
  Future<bool> exists() => real.exists();
  @override
  Future<Uint8List> readAsBytes() => real.readAsBytes();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(ensureSodium);

  test('a delayed authority fetch must not replace a newer saved head',
      () async {
    final album = Uint8List(16);
    final a = Uint8List.fromList(List.filled(32, 1));
    final b = Uint8List.fromList(List.filled(32, 2));
    final c = Uint8List.fromList(List.filled(32, 3));
    final alice = (await newResponderIdentity()).svc;
    final bob = (await newResponderIdentity()).svc;
    final carol = (await newResponderIdentity()).svc;
    final first = await nextHandover(alice,
        albumId: album, chain: [], oldToken: a, newToken: b, newAdmin: bob);
    final second = await nextHandover(bob,
        albumId: album,
        chain: [first],
        oldToken: b,
        newToken: c,
        newAdmin: carol);
    final api = DelayedApi();
    final authority = memoryAuthority(api).authority;
    await authority.anchorCreator(
        albumId: album,
        selfToken: a,
        ikPub: await alice.currentIkPub(),
        lkPub: await alice.currentLkPub());
    final older = authority.sync(album);
    final newer = authority.sync(album);
    // The second sync waits for the first to save before reading the chain
    await pumpEventQueue();
    expect(api.calls.length, 1);
    api.calls[0].complete([first, second]);
    await older;
    expect(authority.chain(album)!.latestTerm, 2);
    await pumpEventQueue();
    expect(api.calls.length, 2);
    // A stale answer now reads as records held back, never as a rollback
    api.calls[1].complete([first]);
    await expectLater(newer, throwsA(isA<AuthorityChainException>()));
    expect(authority.chain(album)!.latestTerm, 2,
        reason: 'a previously saved handover cannot be forgotten');
  });

  test('a failed overlapping save must retain the successful preceding save',
      () async {
    final dir = await Directory.systemTemp.createTemp('miuchio-pin-review-');
    addTearDown(() => dir.delete(recursive: true));
    final real = File('${dir.path}/pins.kec');
    final file = FailSecondWriteFile(real, '${dir.path}/missing/pins.kec');
    final key = Uint8List(32);
    final store = await IdentityPinStore.open(file: file, cacheRootKey: key);
    await store.saveAuthority('album', 'original');
    late Future<void> secondRefused;
    file.afterFirstSnapshot = () {
      secondRefused = expectLater(store.saveAuthority('album', 'second'),
          throwsA(isA<AuthorityNotSaved>()));
    };
    file.armed = true;
    await store.saveAuthority('album', 'first');
    await secondRefused;
    final reopened = await IdentityPinStore.open(file: real, cacheRootKey: key);
    expect(reopened.authority('album'), 'first');
    expect(store.authority('album'), 'first',
        reason: 'memory must keep the authority that actually reached disk');
  });
}
