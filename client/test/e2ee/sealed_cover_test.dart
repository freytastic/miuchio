import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/e2ee/album_keys.dart';
import 'package:miuchio/e2ee/sealed_cover.dart';

import '../_sodium_setup.dart';
import '../secure_store/mock_secure_key_store.dart';

Uint8List _fill(int n, int b) => Uint8List.fromList(List<int>.filled(n, b));

final _album = _fill(16, 0xA1);
final _other = _fill(16, 0xB2);
final _jpeg = Uint8List.fromList(List<int>.generate(5000, (i) => i % 251));

Future<AlbumKeyStore> _keys() async {
  final s = MockSecureKeyStore();
  await s.initialize();
  final aks = AlbumKeyStore(s);
  await aks.initialize();
  await aks.install(_album, 0, _fill(32, 0x11));
  await aks.install(_other, 0, _fill(32, 0x11));
  return aks;
}

Future<Uint8List?> _open(AlbumKeyStore ks, SealedCover c,
        {Uint8List? album, String? coverId}) =>
    CoverCrypto.open(
      ks: ks,
      albumId: album ?? _album,
      coverId: coverId ?? c.coverId,
      keyCt: c.keyCt,
      blobSha256: c.blobSha256,
      blob: c.blob,
    );

void main() {
  setUpAll(ensureSodium);

  test('round trips behind one fixed size the server accepts', () async {
    final ks = await _keys();
    final c = await CoverCrypto.seal(ks: ks, albumId: _album, jpeg: _jpeg);
    final small =
        await CoverCrypto.seal(ks: ks, albumId: _album, jpeg: _fill(10, 1));

    expect(await _open(ks, c), _jpeg);
    expect(small.blob.length, c.blob.length);
    expect(c.blob.length, lessThanOrEqualTo(512 * 1024));
    // Pinned by the server's key_ct length check
    expect(c.keyCt.length, 65);
  });

  test('the server cannot move a cover to another album or id', () async {
    final ks = await _keys();
    final c = await CoverCrypto.seal(ks: ks, albumId: _album, jpeg: _jpeg);
    final twin = await CoverCrypto.seal(ks: ks, albumId: _album, jpeg: _jpeg);

    expect(await _open(ks, c, album: _other), isNull);
    expect(await _open(ks, c, coverId: twin.coverId), isNull);
  });
}
