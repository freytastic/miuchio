import 'dart:convert';

import 'package:miuchio/e2ee/authority_api.dart';

import 'api_client.dart';
import 'api_error.dart';

class ApiClientAuthorityJsonClient implements AuthorityJsonClient {
  final ApiClient _api;
  ApiClientAuthorityJsonClient(this._api);

  @override
  Future<Map<String, dynamic>> getJson(String path) async =>
      jsonDecode((await _api.get(path)).body) as Map<String, dynamic>;

  @override
  Future<Map<String, dynamic>?> getJsonOrNotFound(String path) async {
    try {
      return await getJson(path);
    } on ApiError catch (e) {
      if (e.httpStatus == 404) return null;
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> postJsonForResult(
          String path, Map<String, dynamic> body) async =>
      jsonDecode((await _api.post(path, body: body)).body)
          as Map<String, dynamic>;
}
