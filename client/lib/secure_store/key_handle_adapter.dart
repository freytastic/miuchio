import 'dart:typed_data';
import 'package:miuchio/crypto/primitives.dart';

abstract class KeyHandleAdapter {
  static Future<Ed25519KeyPair> toEd25519(Uint8List seed) =>
      Sign.fromSeed(seed);

  static Future<X25519KeyPair> toX25519(Uint8List priv) => Kex.fromSeed(priv);
}
