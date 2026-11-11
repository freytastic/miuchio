import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/crypto/primitives.dart';
import 'package:miuchio/crypto/uuid_bytes.dart';
import 'package:miuchio/data/api/api_error.dart';
import 'package:miuchio/e2ee/admin_handover.dart';
import 'package:miuchio/e2ee/album_authority.dart';
import 'package:miuchio/e2ee/authority_api.dart';
import 'package:miuchio/e2ee/authority_records.dart';
import 'package:miuchio/e2ee/identity.dart';

import '../_sodium_setup.dart';
import '_admin_test_helpers.dart';
import '_authority_test_helpers.dart';

final _album = Uint8List.fromList(List.generate(16, (i) => 0x60 + i));
final _albumStr = uuidFromBytes(_album);
Uint8List _token(int b) => Uint8List.fromList(List.filled(32, b));
final _alice = _token(0xA1);
final _bob = _token(0xB2);

class _MemoryMarker implements HandoverMarkerStore {
  final Map<String, PendingHandover> byAlbum = {};
  @override
  Future<List<PendingHandover>> read() async => byAlbum.values.toList();
  @override
  Future<void> write(PendingHandover pending) async =>
      byAlbum[pending.albumId] = pending;
  @override
  Future<void> clear(String albumId) async => byAlbum.remove(albumId);
}

// Commits like the server, or fails the way a lost response or a refusal does
class _Server extends FakeAuthorityApi {
  Object? failPost;
  bool commitBeforeFailing = false;
  int lookupFailures = 0;
  final Map<String, HandoverOutcome> committed = {};

  // The membership middleware turns a departed caller away before the
  // handover code can recognize a replay
  bool get _left => committed.values.any((o) => o.left) && !rejoined;
  // Invited back after leaving, so album routes answer again
  bool rejoined = false;

  // A temporary failure of the membership probe, which proves nothing
  ApiError? probeError;

  @override
  Future<List<SignedHandover>> fetchHandovers(Uint8List albumId) async {
    final probe = probeError;
    if (probe != null) throw probe;
    if (_left) {
      throw const ApiError(
          code: 'E_MEMBER_REVOKED', message: 'revoked', httpStatus: 403);
    }
    return super.fetchHandovers(albumId);
  }

  @override
  Future<HandoverOutcome> postHandover(
      Uint8List albumId, Map<String, dynamic> request) async {
    posted.add(request);
    if (_left) {
      throw const ApiError(
          code: 'E_MEMBER_REVOKED', message: 'revoked', httpStatus: 403);
    }
    final op = request['operation_id'] as String;
    final done = committed[op];
    if (done != null) return done;
    final fail = failPost;
    if (fail != null && !commitBeforeFailing) throw fail;
    final outcome =
        HandoverOutcome(albumId: _albumStr, mode: request['mode'] as int);
    committed[op] = outcome;
    if (fail != null) throw fail;
    return outcome;
  }

  @override
  Future<HandoverOutcome?> handoverOutcome(String operationId) async {
    if (lookupFailures > 0) {
      lookupFailures--;
      throw Exception('offline');
    }
    return committed[operationId];
  }
}

void main() {
  setUpAll(ensureSodium);

  late IdentityService alice;
  late IdentityService bob;
  late _Server server;
  late AlbumAuthority authority;
  late _MemoryMarker marker;
  late List<Uint8List> wiped;
  Object? wipeFails;
  late int ops;

  AdminHandoverCoordinator coordinator() => AdminHandoverCoordinator(
        api: server,
        authority: authority,
        identity: alice,
        marker: marker,
        wipeLocalAlbum: (id) async {
          wiped.add(id);
          final f = wipeFails;
          if (f != null) throw f;
        },
        newOperationId: () => '00000000-0000-4000-8000-00000000000${ops++}',
      );

  setUp(() async {
    alice = (await newResponderIdentity()).svc;
    bob = (await newResponderIdentity()).svc;
    server = _Server()
      ..notes = [
        await noteFor(alice,
            albumId: _album, memberToken: _alice, member: alice),
        await noteFor(alice,
            albumId: _album, memberToken: _bob, member: bob, generation: 2),
      ];
    authority = memoryAuthority(server).authority;
    await authority.anchorCreator(
      albumId: _album,
      selfToken: _alice,
      ikPub: await alice.currentIkPub(),
      lkPub: await alice.currentLkPub(),
    );
    marker = _MemoryMarker();
    wiped = [];
    ops = 0;
  });

  test('signs the next term for a vouched successor under their noted keys',
      () async {
    final outcome = await coordinator().handOver(
        albumId: _album, selfToken: _alice, successorToken: _bob, leave: false);

    expect(outcome.left, isFalse);
    final req = server.posted.single;
    expect(req['term'], 1);
    expect(req['mode'], kHandoverStay);
    final record = AdminHandover(
      albumId: _album,
      term: 1,
      prevHash: handoverZeroHash(),
      oldToken: _alice,
      newToken: _bob,
      newGeneration: 2,
      newIkPub: await bob.currentIkPub(),
      newLkPub: await bob.currentLkPub(),
      mode: kHandoverStay,
      deleteMedia: false,
    );
    expect(
        await Sign.verify(await alice.currentIkPub(), record.signedBytes(),
            base64Decode(req['sig'] as String)),
        isTrue);
    expect(marker.byAlbum, isEmpty);
    expect(wiped, isEmpty);
  });

  test('a committed leave wipes the album and clears the marker', () async {
    final outcome = await coordinator().handOver(
        albumId: _album,
        selfToken: _alice,
        successorToken: _bob,
        leave: true,
        deleteMedia: true);

    expect(outcome.left, isTrue);
    expect(server.posted.single['delete_media'], isTrue);
    expect(wiped.single, _album);
    expect(marker.byAlbum, isEmpty);
  });

  test('a lost response is settled by looking the operation up', () async {
    server
      ..failPost = Exception('socket closed')
      ..commitBeforeFailing = true;

    final outcome = await coordinator().handOver(
        albumId: _album, selfToken: _alice, successorToken: _bob, leave: true);

    expect(outcome.left, isTrue);
    expect(wiped, hasLength(1));
    expect(marker.byAlbum, isEmpty);
  });

  test('an unknown outcome keeps the exact request for launch', () async {
    server.failPost = Exception('offline');

    await expectLater(
        coordinator().handOver(
            albumId: _album,
            selfToken: _alice,
            successorToken: _bob,
            leave: true),
        throwsA(isA<HandoverException>()));
    final kept = marker.byAlbum[_albumStr]!;
    expect(wiped, isEmpty);

    server.failPost = null;
    await coordinator().resume();

    expect(server.posted.last, equals(kept.request));
    expect(wiped, hasLength(1));
    expect(marker.byAlbum, isEmpty);
  });

  test('a refusal clears the marker and reaches the caller', () async {
    server.failPost = const ApiError(
        code: 'E_SUCCESSOR_INELIGIBLE', message: 'no', httpStatus: 409);

    await expectLater(
        coordinator().handOver(
            albumId: _album,
            selfToken: _alice,
            successorToken: _bob,
            leave: false),
        throwsA(isA<ApiError>()));
    expect(marker.byAlbum, isEmpty);
  });

  test('a successor no trusted admin vouched for is refused locally', () async {
    await expectLater(
        coordinator().handOver(
            albumId: _album,
            selfToken: _alice,
            successorToken: _token(0xEE),
            leave: false),
        throwsA(isA<HandoverException>()));
    expect(server.posted, isEmpty);
  });

  test('only the admin this device trusts can hand over', () async {
    server.handovers = [
      await nextHandover(alice,
          albumId: _album,
          chain: const [],
          oldToken: _alice,
          newToken: _bob,
          newAdmin: bob),
    ];

    await expectLater(
        coordinator().handOver(
            albumId: _album,
            selfToken: _alice,
            successorToken: _bob,
            leave: false),
        throwsA(isA<HandoverException>()));
    expect(server.posted, isEmpty);
  });

  test('a committed leave whose answer was lost settles at the next connect',
      () async {
    server
      ..failPost = Exception('socket closed')
      ..commitBeforeFailing = true
      ..lookupFailures = 1;

    await expectLater(
        coordinator().handOver(
            albumId: _album,
            selfToken: _alice,
            successorToken: _bob,
            leave: true),
        throwsA(isA<HandoverException>()));
    expect(marker.byAlbum, isNotEmpty);
    expect(wiped, isEmpty);

    server.failPost = null;
    await coordinator().resume();

    // Found by its id, never replayed into the revoked membership
    expect(server.posted, hasLength(1));
    expect(wiped, hasLength(1));
    expect(marker.byAlbum, isEmpty);
  });

  test('a revoked answer with nothing found keeps the marker', () async {
    server
      ..failPost = Exception('socket closed')
      ..commitBeforeFailing = true
      ..lookupFailures = 1;
    await expectLater(
        coordinator().handOver(
            albumId: _album,
            selfToken: _alice,
            successorToken: _bob,
            leave: true),
        throwsA(isA<HandoverException>()));

    // Both lookups at the next connect fail, the replay meets the middleware
    server.lookupFailures = 2;
    await coordinator().resume();

    expect(marker.byAlbum, isNotEmpty);
    expect(wiped, isEmpty);

    await coordinator().resume();
    expect(wiped, hasLength(1));
    expect(marker.byAlbum, isEmpty);
  });

  // An issue i faced when i left, invited back, then the old marker
  // settled on reconnect and wiped the new membership's keys
  test('a leave settled after being invited back keeps the new membership',
      () async {
    server
      ..failPost = Exception('socket closed')
      ..commitBeforeFailing = true
      ..lookupFailures = 1;
    await expectLater(
        coordinator().handOver(
            albumId: _album,
            selfToken: _alice,
            successorToken: _bob,
            leave: true),
        throwsA(isA<HandoverException>()));
    expect(marker.byAlbum, isNotEmpty);

    server
      ..failPost = null
      ..rejoined = true;
    await coordinator().resume();

    expect(wiped, isEmpty);
    expect(marker.byAlbum, isEmpty);
  });

  for (final (status, code) in [
    (500, 'E_INTERNAL'),
    (401, 'E_AUTH'),
    (429, 'E_RATE_LIMITED'),
  ]) {
    test('a $status from the membership probe keeps the marker', () async {
      server
        ..failPost = Exception('socket closed')
        ..commitBeforeFailing = true
        ..lookupFailures = 1;
      await expectLater(
          coordinator().handOver(
              albumId: _album,
              selfToken: _alice,
              successorToken: _bob,
              leave: true),
          throwsA(isA<HandoverException>()));

      server
        ..failPost = null
        ..rejoined = true
        ..probeError =
            ApiError(code: code, message: 'temporary', httpStatus: status);
      await coordinator().resume();

      expect(wiped, isEmpty,
          reason: 'a failed probe is not proof the membership ended');
      expect(marker.byAlbum, isNotEmpty);
    });
  }

  test('a local wipe that fails is retried at the next connect', () async {
    wipeFails = StateError('local storage unavailable');

    final outcome = await coordinator().handOver(
        albumId: _album, selfToken: _alice, successorToken: _bob, leave: true);

    expect(outcome.left, isTrue);
    expect(marker.byAlbum, isNotEmpty);

    wipeFails = null;
    await coordinator().resume();

    expect(wiped, hasLength(2));
    expect(marker.byAlbum, isEmpty);
  });
}
