import 'dart:convert';
import 'package:miuchio/data/models/album_model.dart';
import 'package:miuchio/data/models/member_model.dart';
import 'package:miuchio/data/api/api_client.dart';
import 'package:miuchio/data/api/api_error.dart';
import 'package:miuchio/domain/albums/album_cleanup.dart';

class AlbumService {
  final ApiClient _client = ApiClient();

  // Null distinguishes a failed refresh from an empty shelf
  Future<List<AlbumModel>?> getMyAlbums() async {
    try {
      final response = await _client.get('/albums');
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((json) => AlbumModel.fromJson(json)).toList();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // Only a typed refusal counts as gone: anything else may be transient
  Future<AlbumPresence> probeAlbum(String id) async {
    try {
      final response = await _client.get('/albums/$id');
      return response.statusCode == 200
          ? AlbumPresence.member
          : AlbumPresence.unknown;
    } on ApiError catch (e) {
      return switch (e.code) {
        'E_NOT_MEMBER' || 'E_MEMBER_REVOKED' => AlbumPresence.gone,
        _ => AlbumPresence.unknown,
      };
    } catch (_) {
      return AlbumPresence.unknown;
    }
  }

  Future<AlbumModel?> getAlbum(String id) async {
    try {
      final response = await _client.get('/albums/$id');
      if (response.statusCode == 200) {
        return AlbumModel.fromJson(jsonDecode(response.body));
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // Epoch 0 must install before the real encrypted title can be written
  // This invalid ciphertext safely falls back to Untitled Album
  static const _placeholderNameCt = '////'; // base64 of 0xFF 0xFF 0xFF

  Future<AlbumModel?> createAlbum() async {
    try {
      final response = await _client.post(
        '/albums',
        body: {'name_ct': _placeholderNameCt},
      );
      if (response.statusCode == 201) {
        return AlbumModel.fromJson(jsonDecode(response.body));
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> updateAlbumNameCt(String albumId, String nameCtB64) async {
    try {
      final response = await _client.patch(
        '/albums/$albumId',
        body: {'name_ct': nameCtB64},
      );
      return response.statusCode == 200 || response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }

  // The server resolves the caller's member_token itself
  Future<bool> putProfileCt(String albumId, String nameCtB64) async {
    try {
      final response = await _client.put(
        '/albums/$albumId/members/me/profile-ct',
        body: {'name_ct': nameCtB64},
      );
      return response.statusCode == 200 || response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }

  // Null goes back to the newest photo
  Future<bool> setCover(String albumId, String? mediaId) async {
    try {
      final response = await _client.put(
        '/albums/$albumId/cover',
        body: {'media_id': mediaId},
      );
      return response.statusCode == 200 || response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }

  Future<bool> deleteAlbum(String id) async {
    try {
      final response = await _client.delete('/albums/$id');
      return response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }

  Future<List<AlbumMember>> listMembers(String albumId) async {
    try {
      final response = await _client.get('/albums/$albumId/members');
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((j) => AlbumMember.fromJson(j)).toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  // memberToken is std base64, the path needs unpadded base64url
  Future<bool> removeMember(String albumId, String memberToken,
      {bool deleteMedia = false}) async {
    try {
      final raw = base64.decode(base64.normalize(memberToken));
      final tokenPath = base64Url.encode(raw).replaceAll('=', '');
      final query = deleteMedia ? '?delete_media=true' : '';
      final response =
          await _client.delete('/albums/$albumId/members/$tokenPath$query');
      return response.statusCode == 204;
    } catch (_) {
      return false;
    }
  }
}
