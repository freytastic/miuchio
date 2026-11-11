import 'dart:convert';

import 'package:miuchio/e2ee/invite_api.dart';

import 'api_client.dart';
import 'api_error.dart';

class ApiClientInviteJsonClient implements InviteJsonClient {
  final ApiClient _api;
  ApiClientInviteJsonClient(this._api);

  @override
  Future<Map<String, dynamic>> postJsonForResult(
      String path, Map<String, dynamic> body) async {
    try {
      final resp = await _api.post(path, body: body);
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } on ApiError catch (e) {
      final token = e.detail['member_token'];
      final generation = e.detail['generation'];
      if (e.code != 'E_MEMBER_TOKEN_MISMATCH' ||
          token is! String ||
          generation is! num) {
        rethrow;
      }
      throw MemberTokenMismatch(
          memberToken: base64Decode(token), generation: generation.toInt());
    }
  }

  @override
  Future<void> postJson(String path, Map<String, dynamic> body) async {
    await _api.post(path, body: body);
  }
}
