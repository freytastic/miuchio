import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;

abstract class BlobDigest {
  static const int _inlineMax = 256 * 1024;

  // The Dart digest runs synchronously, so large blobs would stall frames
  static Future<Uint8List> sha256(Uint8List bytes) => bytes.length <= _inlineMax
      ? _sha256(bytes)
      : Isolate.run(() => _sha256(bytes));
}

Future<Uint8List> _sha256(Uint8List bytes) async =>
    Uint8List.fromList((await cg.Sha256().hash(bytes)).bytes);
