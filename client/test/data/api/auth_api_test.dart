import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:miuchio/data/api/auth_api.dart';
import 'package:miuchio/data/storage/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const userId = '11111111-1111-4111-8111-111111111111';

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  http.Client okClient() => MockClient((_) async => http.Response(
        jsonEncode({
          'user_id': userId,
          'token': 'tok',
          'refreshToken': 'tok',
          'expiresAt': '2030-01-01T00:00:00Z',
        }),
        200,
      ));

  // Verification must not bypass the vault owner check by persisting early
  test('verifyOtp returns the pending session without persisting it', () async {
    final auth = AuthService(client: okClient());

    final pending = await auth.verifyOtp('a@example.com', '123456');

    expect(pending, isNotNull);
    expect(pending!.userId, userId);
    expect(pending.token, 'tok');

    final storage = StorageService();
    expect(await storage.getToken(), isNull,
        reason: 'credentials must not be written before the owner check');
    expect(await storage.getUserId(), isNull);
  });

  test('commit persists the session and the account it belongs to', () async {
    final auth = AuthService(client: okClient());
    final pending = await auth.verifyOtp('a@example.com', '123456');

    await auth.commit(pending!, email: 'a@example.com');

    final storage = StorageService();
    expect(await storage.getToken(), 'tok');
    expect(await storage.getUserId(), userId);
    expect(await storage.getEmail(), 'a@example.com');
  });

  test('verifyOtp returns null when the code is rejected', () async {
    final auth = AuthService(
      client: MockClient((_) async => http.Response('{}', 401)),
    );
    expect(await auth.verifyOtp('a@example.com', '000000'), isNull);
  });

  Future<Map<String, dynamic>> sentBody(String email) async {
    late Map<String, dynamic> body;
    final auth = AuthService(
      client: MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('{}', 401);
      }),
      installId: () async => '0123456789abcdef0123456789abcdef',
    );
    await auth.verifyOtp(email, '123456');
    return body;
  }

  test('verifyOtp sends the install id only for a review address', () async {
    expect(
        (await sentBody(' Review-K3J9X2M8Q4W7P1Z5@Miuchio.com '))['install_id'],
        '0123456789abcdef0123456789abcdef');
    for (final email in [
      'a@example.com',
      'review@miuchio.com',
      'review-short@miuchio.com'
    ]) {
      expect((await sentBody(email)).containsKey('install_id'), isFalse,
          reason: email);
    }
  });

  test('verifyOtp reports a rate limit instead of a wrong code', () async {
    final auth = AuthService(
      client: MockClient((_) async => http.Response(
          jsonEncode({'code': 'E_RATE_LIMITED', 'message': 'too many'}), 429)),
      installId: () async => '0123456789abcdef0123456789abcdef',
    );
    expect(() => auth.verifyOtp('a@example.com', '000000'),
        throwsA(isA<TooManyAttemptsException>()));
  });
}
