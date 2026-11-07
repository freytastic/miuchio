import 'dart:convert';
import 'dart:typed_data';

import 'api_client.dart';

class BlockRecord {
  final String id;
  final DateTime createdAt;

  const BlockRecord({required this.id, required this.createdAt});

  static BlockRecord? tryFromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final id = json['id'];
    final at = DateTime.tryParse(json['created_at'] as String? ?? '');
    if (id is! String || at == null) return null;
    return BlockRecord(id: id, createdAt: at);
  }
}

// The server only ever sees the sealed report and who it is about
class SafetyApi {
  final ApiClient _api;

  SafetyApi(this._api);

  Future<void> report(
    String albumId, {
    required String kind,
    String? mediaId,
    String? memberToken,
    required Uint8List sealed,
  }) =>
      _api.post('/albums/$albumId/reports', body: {
        'kind': kind,
        if (mediaId != null) 'media_id': mediaId,
        if (memberToken != null) 'member_token': memberToken,
        'sealed': base64Encode(sealed),
      });

  Future<BlockRecord> block(String albumId, String memberToken) async {
    final resp = await _api
        .post('/albums/$albumId/blocks', body: {'member_token': memberToken});
    final b = BlockRecord.tryFromJson(jsonDecode(resp.body));
    if (b == null) throw const FormatException('bad block response');
    return b;
  }

  Future<List<BlockRecord>> blocks() async {
    final resp = await _api.get('/blocks');
    final raw = (jsonDecode(resp.body) as Map<String, dynamic>)['blocks'];
    if (raw is! List) return const [];
    return raw.map(BlockRecord.tryFromJson).nonNulls.toList();
  }

  Future<void> unblock(String id) => _api.delete('/blocks/$id');
}
