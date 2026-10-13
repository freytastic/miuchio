import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:miuchio/secure_store/secure_key_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // The host contract test proves the zeroing itself. This only confirms the
  // same path runs on the real store, heap inspection would need vm_service
  test('use<T> zeroing path runs cleanly on the real impl', () async {
    final s = createSecureKeyStore();
    await s.initialize();
    final sentinel = Uint8List.fromList(List.filled(32, 0xDE));
    final h = await s.put('zero.k', sentinel);

    Uint8List? captured;
    await s.use<void>(h, (b) async {
      // Touch the bytes so they are materialized
      var sum = 0;
      for (final x in b) {
        sum += x;
      }
      expect(sum, 32 * 0xDE);
      captured = b;
    });

    expect(captured, isNotNull);
    expect(captured!.every((x) => x == 0), isTrue,
        reason: 'store-handed buffer must be zeroed after use<T>');
    // The caller's own copy must be untouched
    expect(sentinel.every((x) => x == 0xDE), isTrue);

    await s.wipeAll();
  });
}
