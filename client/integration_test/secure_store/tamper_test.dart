import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:miuchio/secure_store/key_store_exceptions.dart';
import 'package:miuchio/secure_store/secure_key_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Android only: the iOS Keychain is sandboxed from the test process, so iOS
  // would need a debug only tamper hook in SecureEnclaveBridge
  test('flipped byte in envelope causes KeyTamperException (Android-only)',
      () async {
    if (!Platform.isAndroid) return;
    final store = createSecureKeyStore();
    await store.initialize();
    final h =
        await store.put('tamper.k', Uint8List.fromList(List.filled(32, 0xCC)));

    // On Android this is ctx.filesDir, where KeystoreBridge writes the envelope
    final docs = await getApplicationSupportDirectory();
    final f = File('${docs.path}/miuchio_secure_store.bin');
    expect(f.existsSync(), isTrue);
    final raw = f.readAsBytesSync();
    raw[raw.length - 1] ^= 0x01;
    f.writeAsBytesSync(raw);

    await expectLater(
        store.use(h, (_) async => 0), throwsA(isA<KeyTamperException>()));
    await store.wipeAll();
  });
}
