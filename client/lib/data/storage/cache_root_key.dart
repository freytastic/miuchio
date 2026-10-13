import 'dart:typed_data';

import 'package:miuchio/crypto/primitives.dart';
import 'package:miuchio/secure_store/key_handle.dart';
import 'package:miuchio/secure_store/secure_key_store.dart';

const String kCacheRootKeyLabel = 'cache_root_key';
const int kCacheRootKeyLen = 32;

// Device bound key sealing the disk caches, independent of album MKs so a
// rotation never invalidates them. The caller owns the returned copy
Future<Uint8List> loadOrCreateCacheRootKey(SecureKeyStore store) async {
  final existing = await store.list(labelPrefix: kCacheRootKeyLabel);
  final KeyHandle handle = existing.isNotEmpty
      ? existing.first
      : await store.put(kCacheRootKeyLabel, Csprng.bytes(kCacheRootKeyLen));
  return store.use(handle, (raw) async => Uint8List.fromList(raw));
}

// Full reset only, logout keeps the key. Leftover .kec files become unreadable
Future<void> deleteCacheRootKey(SecureKeyStore store) async {
  for (final h in await store.list(labelPrefix: kCacheRootKeyLabel)) {
    await store.delete(h);
  }
}
