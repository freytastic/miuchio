import 'package:flutter_test/flutter_test.dart';

import 'package:miuchio/data/storage/cache_root_key.dart';

import '../../secure_store/mock_secure_key_store.dart';

void main() {
  late MockSecureKeyStore store;

  setUp(() async {
    store = MockSecureKeyStore();
    await store.initialize();
  });

  test('creates one key and reuses it on the next load', () async {
    final first = await loadOrCreateCacheRootKey(store);
    expect(first.length, kCacheRootKeyLen);
    final second = await loadOrCreateCacheRootKey(store);
    expect(second, equals(first));
    final handles = await store.list(labelPrefix: kCacheRootKeyLabel);
    expect(handles.length, 1);
  });

  test('deleteCacheRootKey removes the handle; next load mints a fresh key',
      () async {
    final first = await loadOrCreateCacheRootKey(store);
    await deleteCacheRootKey(store);
    expect(await store.list(labelPrefix: kCacheRootKeyLabel), isEmpty);
    final second = await loadOrCreateCacheRootKey(store);
    expect(second, isNot(equals(first)));
  });
}
