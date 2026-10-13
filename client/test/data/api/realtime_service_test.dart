import 'package:test/test.dart';
import 'package:miuchio/data/api/api_client.dart';
import 'package:miuchio/data/api/realtime_service.dart';

void main() {
  group('RealtimeService.connected', () {
    // Several catch up consumers listen at once
    test('exposes a broadcast stream', () {
      final svc = RealtimeService(ApiClient());
      expect(svc.connected.isBroadcast, isTrue);
      svc.dispose();
    });
  });

  group('RealtimeService.buildWsUri', () {
    test('builds the ws url from the api base and ticket', () {
      final plain = RealtimeService.buildWsUri(
          'http://localhost:8080/api/v1', 'my-ticket-42');
      expect(plain.scheme, equals('ws'));
      expect(plain.queryParameters['ticket'], equals('my-ticket-42'));
      expect(plain.path, endsWith('/ws'));

      final secure =
          RealtimeService.buildWsUri('https://api.miuchio.app/api/v1', 'abc');
      expect(secure.scheme, equals('wss'));
    });

    test('URL does not contain Authorization header value or token= param', () {
      final uri = RealtimeService.buildWsUri(
          'http://localhost:8080/api/v1', 'my-ticket');
      final urlStr = uri.toString();
      expect(urlStr, isNot(contains('Authorization')));
      expect(urlStr, isNot(contains('token=')));
    });
  });
}
