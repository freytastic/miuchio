import 'dart:convert';
import 'dart:typed_data';

import 'package:miuchio/crypto/uuid_bytes.dart';

import 'authority_records.dart';

class HandoverOutcome {
  final String albumId;
  final int mode;
  const HandoverOutcome({required this.albumId, required this.mode});
  bool get left => mode == kHandoverLeave;
}

abstract class AuthorityApi {
  // The notes of every active member for their current membership
  Future<({int adminTerm, List<SignedNote> notes})> fetchNotes(
      Uint8List albumId);

  // The whole chain in term order
  Future<List<SignedHandover>> fetchHandovers(Uint8List albumId);

  Future<HandoverOutcome> postHandover(
      Uint8List albumId, Map<String, dynamic> request);

  // Null when the server never committed this operation
  Future<HandoverOutcome?> handoverOutcome(String operationId);
}

abstract class AuthorityJsonClient {
  Future<Map<String, dynamic>> getJson(String path);
  Future<Map<String, dynamic>?> getJsonOrNotFound(String path);
  Future<Map<String, dynamic>> postJsonForResult(
      String path, Map<String, dynamic> body);
}

class HttpAuthorityApi implements AuthorityApi {
  final AuthorityJsonClient _client;
  HttpAuthorityApi(this._client);

  @override
  Future<({int adminTerm, List<SignedNote> notes})> fetchNotes(
      Uint8List albumId) async {
    final body =
        await _client.getJson('/albums/${uuidFromBytes(albumId)}/notes');
    return (
      adminTerm: (body['admin_term'] as num).toInt(),
      notes: [
        for (final n in (body['notes'] as List? ?? const []))
          SignedNote.fromJson(albumId, n as Map<String, dynamic>),
      ],
    );
  }

  @override
  Future<List<SignedHandover>> fetchHandovers(Uint8List albumId) async {
    final body =
        await _client.getJson('/albums/${uuidFromBytes(albumId)}/handovers');
    return [
      for (final h in (body['handovers'] as List? ?? const []))
        SignedHandover.fromJson(albumId, h as Map<String, dynamic>),
    ];
  }

  @override
  Future<HandoverOutcome> postHandover(
          Uint8List albumId, Map<String, dynamic> request) async =>
      _outcome(await _client.postJsonForResult(
          '/albums/${uuidFromBytes(albumId)}/handover', request));

  @override
  Future<HandoverOutcome?> handoverOutcome(String operationId) async {
    final body =
        await _client.getJsonOrNotFound('/album-handovers/$operationId');
    return body == null ? null : _outcome(body);
  }

  HandoverOutcome _outcome(Map<String, dynamic> body) => HandoverOutcome(
        albumId: body['album_id'] as String,
        mode: (body['mode'] as num).toInt(),
      );
}

// The body of POST /albums/{id}/handover. The server rebuilds the signed
// record from its own rows, so only the caller's choices travel
Map<String, dynamic> handoverRequest({
  required SignedHandover signed,
  required String operationId,
}) =>
    {
      'new_admin_token': base64Encode(signed.handover.newToken),
      'term': signed.handover.term,
      'mode': signed.handover.mode,
      'delete_media': signed.handover.deleteMedia,
      'sig': base64Encode(signed.sig),
      'operation_id': operationId,
    };
