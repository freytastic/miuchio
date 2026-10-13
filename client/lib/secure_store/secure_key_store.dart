import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'android_keystore.dart';
import 'ios_secure_enclave.dart';
import 'key_handle.dart';
import 'key_store_exceptions.dart';

// Private keys live behind handles. Raw bytes reach the Dart heap only inside
// use(), and are zeroed when its callback finishes
abstract class SecureKeyStore {
  Future<void> initialize();

  Future<KeyHandle> put(String label, Uint8List plaintext);

  // Handles come back in input order. Native overrides do one envelope rewrite
  // for the whole batch
  Future<List<KeyHandle>> putMany(
      List<({String label, Uint8List plaintext})> entries) async {
    final out = <KeyHandle>[];
    for (final e in entries) {
      out.add(await put(e.label, e.plaintext));
    }
    return out;
  }

  // The buffer is zeroed after fn returns or throws
  Future<T> use<T>(KeyHandle h, Future<T> Function(Uint8List bytes) fn);

  Future<void> delete(KeyHandle h);

  Future<List<KeyHandle>> list({String? labelPrefix});

  // Deletes the wrapping key and the envelope, every handle becomes invalid
  Future<void> wipeAll();

  @visibleForTesting
  Future<Uint8List> getOnce(KeyHandle h);
}

SecureKeyStore createSecureKeyStore() {
  if (Platform.isAndroid) return AndroidKeystore();
  if (Platform.isIOS) return IosSecureEnclave();
  throw PlatformUnsupportedException(Platform.operatingSystem);
}
