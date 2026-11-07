import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/data/api/safety_api.dart';
import 'package:miuchio/data/storage/media_cache_manager.dart';
import 'package:miuchio/domain/safety/reporter.dart';
import 'package:miuchio/e2ee/album_keys.dart';
import 'package:sodium/sodium_sumo.dart';

import '../../_sodium_setup.dart';

class _Api implements SafetyApi {
  final sent =
      <({String albumId, String kind, String? token, Uint8List sealed})>[];

  @override
  Future<void> report(String albumId,
      {required String kind,
      String? mediaId,
      String? memberToken,
      required Uint8List sealed}) async {
    sent.add(
        (albumId: albumId, kind: kind, token: memberToken, sealed: sealed));
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Unused implements MediaCacheManager, AlbumKeyStore {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  late SodiumSumo sodium;

  setUpAll(() async => sodium = await ensureSodium());

  test('a person report opens only with the moderation key', () async {
    final keys = sodium.crypto.box.keyPair();
    final api = _Api();
    final reporter = Reporter(
      api: api,
      aks: _Unused(),
      cache: _Unused(),
      publicKey: base64Encode(keys.publicKey),
    );

    await reporter.person(
        'album-1',
        'dG9rZW4=',
        const ReportDraft(ReportReason.harassment,
            note: '  keeps adding me  '));

    final sent = api.sent.single;
    expect(sent.kind, 'person');
    expect(sent.token, 'dG9rZW4=');
    final opened = sodium.crypto.box.sealOpen(
        cipherText: sent.sealed,
        publicKey: keys.publicKey,
        secretKey: keys.secretKey);
    final json = jsonDecode(utf8.decode(opened)) as Map<String, dynamic>;
    // The fields server/cmd/mod/main.go reads
    expect(json['v'], 1);
    expect(json['kind'], 'person');
    expect(json['reason'], 'harassment');
    expect(json['note'], 'keeps adding me');
    expect(json['album_id'], 'album-1');
    expect(json['member_token'], 'dG9rZW4=');
    keys.secretKey.dispose();
  });

  test('without a moderation key nothing is sent', () async {
    final api = _Api();
    final reporter =
        Reporter(api: api, aks: _Unused(), cache: _Unused(), publicKey: '');
    await expectLater(
        reporter.person('a', 't', const ReportDraft(ReportReason.other)),
        throwsStateError);
    expect(api.sent, isEmpty);
  });
}
