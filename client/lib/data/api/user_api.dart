import 'dart:convert';
import 'package:miuchio/data/api/api_client.dart';

class UserService {
  final ApiClient _client = ApiClient();

  Future<Map<String, dynamic>?> getMe() async {
    try {
      final response = await _client.get('/users/me');
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> setDeleteMediaOnLeave(bool on) async {
    try {
      final response = await _client.put('/users/me/preferences',
          body: {'delete_media_on_leave': on});
      return response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }
}
