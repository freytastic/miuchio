import 'dart:convert';
import 'dart:typed_data';

import 'prekey_bundle.dart';

// Bodies use standard base64, path segments use unpadded base64url

class PrekeyOpk {
  final int idx;
  final Uint8List keyPub;
  const PrekeyOpk({required this.idx, required this.keyPub});
}

// Server held key state used only to reconcile ambiguous publications. Local
// private keys remain the authority for identity decisions
class OwnKeys {
  final Uint8List ikPub;
  final Uint8List lkPub;
  final Uint8List spkPub;
  final int? spkTs;
  const OwnKeys({
    required this.ikPub,
    required this.lkPub,
    required this.spkPub,
    required this.spkTs,
  });

  factory OwnKeys.fromJson(Map<String, dynamic> json) {
    Uint8List dec(String? s) =>
        s == null || s.isEmpty ? Uint8List(0) : base64Decode(s);
    final ts = json['spk_ts'];
    return OwnKeys(
      ikPub: dec(json['ik_pub'] as String?),
      lkPub: dec(json['lk_pub'] as String?),
      spkPub: dec(json['spk_pub'] as String?),
      spkTs: ts is num ? ts.toInt() : null,
    );
  }
}

// Translated from ApiError by the adapter so e2ee/ never imports data/
class PrekeyApiException implements Exception {
  final String code;
  final String message;
  final int httpStatus;
  const PrekeyApiException({
    required this.code,
    required this.message,
    required this.httpStatus,
  });
  @override
  String toString() =>
      'PrekeyApiException($code, http=$httpStatus, message="$message")';
}

abstract class PrekeyJsonClient {
  Future<Map<String, dynamic>> getJson(String path);
  Future<void> postJson(String path, Map<String, dynamic> body);
  Future<void> putJson(String path, Map<String, dynamic> body);
}

abstract class PrekeyApi {
  Future<void> upsertIdentity({
    required Uint8List ikPub,
    required Uint8List lkPub,
    required Uint8List spkPub,
    required Uint8List spkSig,
    required int spkTs,
  });

  Future<void> rotateSpk({
    required Uint8List spkPub,
    required Uint8List spkSig,
    required int spkTs,
    required Uint8List rotationSig,
  });

  Future<void> replenishOpks({
    required List<PrekeyOpk> opks,
    required Uint8List replenishSig,
  });

  Future<int> opkCount();

  // Unlike bundle fetches this pops no OPK
  Future<OwnKeys> fetchOwnKeys();

  // Unverified, callers must run PrekeyBundle.verify() before X3DH
  Future<PrekeyBundle> fetchPrekeyBundle(String userId);

  // userId on the result is the miuchio_id, the server never reveals the
  // real user_id here
  Future<PrekeyBundle> fetchPrekeyBundleByHandle(String handle);
}

// Unknown and malformed IDs are indistinguishable on purpose
class HandleNotFoundException implements Exception {
  final String handle;
  const HandleNotFoundException(this.handle);
  @override
  String toString() => 'HandleNotFoundException($handle)';
}

// Member removal knows remaining members only by member_token, never user_id
abstract class MemberBundleFetcher {
  // userId on the result is the member_token
  Future<PrekeyBundle> fetchPrekeyBundleByMemberToken(
    String albumId,
    Uint8List memberToken,
  );
}

// Revoked, removed and foreign tokens are indistinguishable on purpose
class MemberBundleNotFoundException implements Exception {
  const MemberBundleNotFoundException();
  @override
  String toString() => 'MemberBundleNotFoundException()';
}

class HttpPrekeyApi implements PrekeyApi, MemberBundleFetcher {
  final PrekeyJsonClient _client;
  HttpPrekeyApi(this._client);

  @override
  Future<PrekeyBundle> fetchPrekeyBundleByMemberToken(
    String albumId,
    Uint8List memberToken,
  ) async {
    final tokenPath = base64Url.encode(memberToken).replaceAll('=', '');
    try {
      final body = await _client
          .getJson('/albums/$albumId/members/$tokenPath/prekey-bundle');
      return PrekeyBundle.fromJson(body);
    } on PrekeyApiException catch (e) {
      if (e.httpStatus == 404) {
        throw const MemberBundleNotFoundException();
      }
      rethrow;
    }
  }

  @override
  Future<void> upsertIdentity({
    required Uint8List ikPub,
    required Uint8List lkPub,
    required Uint8List spkPub,
    required Uint8List spkSig,
    required int spkTs,
  }) {
    return _client.putJson('/users/me/keys', {
      'ik_pub': base64Encode(ikPub),
      'lk_pub': base64Encode(lkPub),
      'spk_pub': base64Encode(spkPub),
      'spk_sig': base64Encode(spkSig),
      'spk_ts': spkTs,
    });
  }

  @override
  Future<void> rotateSpk({
    required Uint8List spkPub,
    required Uint8List spkSig,
    required int spkTs,
    required Uint8List rotationSig,
  }) {
    return _client.postJson('/users/me/spk', {
      'spk_pub': base64Encode(spkPub),
      'spk_sig': base64Encode(spkSig),
      'spk_ts': spkTs,
      'rotation_sig': base64Encode(rotationSig),
    });
  }

  @override
  Future<void> replenishOpks({
    required List<PrekeyOpk> opks,
    required Uint8List replenishSig,
  }) {
    return _client.postJson('/users/me/opks', {
      'opks': [
        for (final o in opks) {'idx': o.idx, 'key_pub': base64Encode(o.keyPub)},
      ],
      'replenish_sig': base64Encode(replenishSig),
    });
  }

  @override
  Future<int> opkCount() async {
    final body = await _client.getJson('/users/me/opks/count');
    return body['count'] as int;
  }

  @override
  Future<OwnKeys> fetchOwnKeys() async {
    final body = await _client.getJson('/users/me/keys');
    return OwnKeys.fromJson(body);
  }

  @override
  Future<PrekeyBundle> fetchPrekeyBundle(String userId) async {
    final body = await _client.getJson('/users/$userId/prekey-bundle');
    return PrekeyBundle.fromJson(body);
  }

  @override
  Future<PrekeyBundle> fetchPrekeyBundleByHandle(String handle) async {
    try {
      final body =
          await _client.getJson('/users/by-handle/$handle/prekey-bundle');
      return PrekeyBundle.fromJson(body);
    } on PrekeyApiException catch (e) {
      if (e.httpStatus == 404) {
        throw HandleNotFoundException(handle);
      }
      rethrow;
    }
  }
}
