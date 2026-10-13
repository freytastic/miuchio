import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:miuchio/secure_store/secure_key_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // A fresh store instance stands in for a restart, since the wrapper key and
  // envelope live in OS storage. A real kill test would need two processes
  test('survives store-instance reboot', () async {
    final s1 = createSecureKeyStore();
    await s1.initialize();
    final pt = Uint8List.fromList(List.generate(32, (i) => i ^ 0x5A));
    final h = await s1.put('reboot.key', pt);

    final s2 = createSecureKeyStore();
    await s2.initialize();
    final got = await s2.use(h, (b) async => Uint8List.fromList(b));
    expect(got, equals(pt));

    await s2.wipeAll();
  });
}
