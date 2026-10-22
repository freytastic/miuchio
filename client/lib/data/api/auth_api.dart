import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:miuchio/data/api/api_error.dart';
import 'package:miuchio/data/constants.dart';
import 'package:miuchio/data/storage/install_id.dart' as install;
import 'package:miuchio/data/storage/storage_service.dart';

// Store reviewers sign in with a fixed code and get one account per
// installation. The server's REVIEW_EMAIL is secret but has this shape
final _reviewEmail = RegExp(r'^review-[a-z0-9]{16,}@miuchio\.com$');

// Sign in reached an account whose deletion is still being finished
class AccountDeletingException implements Exception {
  const AccountDeletingException();
}

// Too many wrong codes, so retyping cannot help yet
class TooManyAttemptsException implements Exception {
  const TooManyAttemptsException();
}

// Verified credentials held in memory until the vault owner check passes
class PendingSession {
  final String userId;
  final String token;
  final String refreshToken;
  final String expiresAt;

  const PendingSession({
    required this.userId,
    required this.token,
    required this.refreshToken,
    required this.expiresAt,
  });
}

class AuthService {
  final StorageService _storage = StorageService();
  final http.Client _client;
  final Future<String> Function() _installId;

  AuthService({http.Client? client, Future<String> Function()? installId})
      : _client = client ?? http.Client(),
        _installId = installId ?? install.installId;

  Future<bool> requestOtp(String email) async {
    try {
      final url = Uri.parse('${AppConstants.baseURL}/auth/otp/request');
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email}),
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // Returns verified credentials without persisting them
  Future<PendingSession?> verifyOtp(String email, String code) async {
    try {
      final url = Uri.parse('${AppConstants.baseURL}/auth/otp/verify');
      final body = {'email': email, 'otp': code};
      // Real accounts never send a per installation identifier
      if (_reviewEmail.hasMatch(email.trim().toLowerCase())) {
        body['install_id'] = await _installId();
      }
      final response = await _client.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final userId = data['user_id'] as String?;
        final token = data['token'] as String?;
        final refreshToken = data['refreshToken'] as String?;
        final expiresAt = data['expiresAt'] as String?;

        if (userId != null &&
            token != null &&
            refreshToken != null &&
            expiresAt != null) {
          return PendingSession(
            userId: userId,
            token: token,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
          );
        }
      }
      final error = ApiError.tryParse(response);
      if (error?.code == 'E_ACCOUNT_DELETING') {
        throw const AccountDeletingException();
      }
      if (error?.isRateLimited ?? false) {
        throw const TooManyAttemptsException();
      }
      return null;
    } catch (e) {
      rethrow;
    }
  }

  // Persists credentials only after the vault owner check succeeds
  Future<void> commit(PendingSession session, {required String email}) async {
    await _storage.saveAuth(
        session.token, session.refreshToken, session.expiresAt);
    await _storage.saveUserId(session.userId);
    // Cache the email because the server stores only its HMAC
    await _storage.saveEmail(email);
  }

  Future<void> logout() async {
    await _storage.deleteAuth();
  }
}
