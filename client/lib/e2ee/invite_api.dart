import 'dart:convert';
import 'dart:typed_data';

// senderSig signs SHA256(album_id ‖ u32_be(epoch) ‖ wrap)
class DeliverEnvelope {
  final int epoch;
  final Uint8List wrapNonce;
  final Uint8List wrapTagCt;
  final Uint8List senderSig;
  const DeliverEnvelope({
    required this.epoch,
    required this.wrapNonce,
    required this.wrapTagCt,
    required this.senderSig,
  });
}

abstract class InviteApi {
  // Returns the new member_token
  Future<Uint8List> deliverExistingUser({
    required String albumId,
    required String targetMiuchioId,
    required Uint8List ekPub,
    int? opkIdx,
    required List<DeliverEnvelope> envelopes,
  });

  // Signed receipt that the caller installed 'epoch'
  Future<void> postJoinComplete({
    required String albumId,
    required int epoch,
    required Uint8List ekPubAdmin,
    required Uint8List sig,
  });
}

abstract class InviteJsonClient {
  Future<Map<String, dynamic>> postJsonForResult(
      String path, Map<String, dynamic> body);
  Future<void> postJson(String path, Map<String, dynamic> body);
}

class HttpInviteApi implements InviteApi {
  final InviteJsonClient _client;
  HttpInviteApi(this._client);

  @override
  Future<Uint8List> deliverExistingUser({
    required String albumId,
    required String targetMiuchioId,
    required Uint8List ekPub,
    int? opkIdx,
    required List<DeliverEnvelope> envelopes,
  }) async {
    final body = await _client
        .postJsonForResult('/albums/$albumId/invites/existing-user', {
      'target_miuchio_id': targetMiuchioId,
      'ek_pub': base64Encode(ekPub),
      'opk_idx_used': opkIdx,
      'envelopes': [
        for (final e in envelopes)
          {
            'epoch': e.epoch,
            'wrap_nonce': base64Encode(e.wrapNonce),
            'wrap_tag_ct': base64Encode(e.wrapTagCt),
            'sender_sig': base64Encode(e.senderSig),
          },
      ],
    });
    return base64Decode(body['member_token'] as String);
  }

  @override
  Future<void> postJoinComplete({
    required String albumId,
    required int epoch,
    required Uint8List ekPubAdmin,
    required Uint8List sig,
  }) {
    return _client.postJson('/albums/$albumId/joins', {
      'epoch': epoch,
      'ek_pub_admin': base64Encode(ekPubAdmin),
      'sig': base64Encode(sig),
    });
  }
}
