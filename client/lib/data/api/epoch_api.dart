import 'dart:convert';

import 'package:miuchio/e2ee/epoch_api.dart';

import 'api_client.dart';
import 'api_error.dart';

// Maps 404 to null so HttpEpochApi can tell a missing wrap or epoch apart

class ApiClientEpochJsonClient implements EpochJsonClient {
  final ApiClient _api;
  ApiClientEpochJsonClient(this._api);

  @override
  Future<Map<String, dynamic>?> getJsonOrNotFound(String path) async {
    try {
      final resp = await _api.get(path);
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } on ApiError catch (e) {
      if (e.httpStatus == 404) return null;
      rethrow;
    }
  }

  @override
  Future<void> postJson(String path, Map<String, dynamic> body) async {
    await _api.post(path, body: body);
  }
}
