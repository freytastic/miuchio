import 'dart:typed_data';
import 'package:cryptography/cryptography.dart' as cg;
import 'package:sodium/sodium_sumo.dart';
import 'wire_format.dart';

// Private bytes are 32B seeds, the same form SecureKeyStore persists
class Ed25519KeyPair {
  final Uint8List seed;
  final Uint8List publicKey;
  Ed25519KeyPair({required this.seed, required this.publicKey})
      : assert(seed.length == 32, 'Ed25519 seed must be 32B'),
        assert(publicKey.length == 32, 'Ed25519 pub must be 32B');
}

class X25519KeyPair {
  final Uint8List privateKey;
  final Uint8List publicKey;
  X25519KeyPair({required this.privateKey, required this.publicKey})
      : assert(privateKey.length == 32, 'X25519 priv must be 32B'),
        assert(publicKey.length == 32, 'X25519 pub must be 32B');
}

// Tag failure, kept apart from FormatException so callers can tell tampered
// bytes from malformed ones
class AeadAuthFailed implements Exception {
  final String message;
  AeadAuthFailed([this.message = 'AEAD authentication failed']);
  @override
  String toString() => 'AeadAuthFailed: $message';
}

// Fresh random 96 bit nonce per call, always framed as VER||NONCE||TAG||CT
abstract class Aead {
  static Future<Uint8List> encrypt({
    required int version,
    required Uint8List key,
    required Uint8List plaintext,
    required Uint8List aad,
  }) async {
    if (key.length != 32) {
      throw ArgumentError('key must be 32 bytes, got ${key.length}');
    }
    final algo = _algoFor(version);
    final box = await algo.encrypt(
      plaintext,
      secretKey: cg.SecretKey(key),
      aad: aad,
    );
    return WireFormat.assemble(
      version: version,
      nonce: Uint8List.fromList(box.nonce),
      tag: Uint8List.fromList(box.mac.bytes),
      ciphertext: Uint8List.fromList(box.cipherText),
    );
  }

  static Future<Uint8List> decrypt({
    required Uint8List wire,
    required Uint8List key,
    required Uint8List aad,
  }) async {
    if (key.length != 32) {
      throw ArgumentError('key must be 32 bytes, got ${key.length}');
    }
    final parsed = WireFormat.parse(wire);
    if (parsed.version == kVerStreamGcm) {
      throw UnimplementedError(
          'VER=0x03 is segmented: use AeadStream.decryptBytes');
    }
    final algo = _algoFor(parsed.version);
    final box = cg.SecretBox(
      parsed.ciphertext,
      nonce: parsed.nonce,
      mac: cg.Mac(parsed.tag),
    );
    try {
      final pt = await algo.decrypt(
        box,
        secretKey: cg.SecretKey(key),
        aad: aad,
      );
      return Uint8List.fromList(pt);
    } on cg.SecretBoxAuthenticationError catch (e) {
      throw AeadAuthFailed(e.toString());
    }
  }

  static cg.Cipher _algoFor(int version) {
    switch (version) {
      case kVerAesGcm:
        return cg.AesGcm.with256bits();
      case kVerChaPo:
        return cg.Chacha20.poly1305Aead();
      case kVerStreamGcm:
        throw UnimplementedError('VER=0x03 is segmented: use AeadStream');
      default:
        throw FormatException(
            'unknown VER: 0x${version.toRadixString(16).padLeft(2, '0')}');
    }
  }
}

abstract class Hkdf {
  static Future<Uint8List> derive({
    required Uint8List ikm,
    required Uint8List salt,
    required Uint8List info,
    required int length,
  }) async {
    final hkdf = cg.Hkdf(hmac: cg.Hmac.sha256(), outputLength: length);
    final out = await hkdf.deriveKey(
      secretKey: cg.SecretKey(ikm),
      nonce: salt,
      info: info,
    );
    return Uint8List.fromList(await out.extractBytes());
  }
}

// Sumo build is needed for raw scalarmult. bindSodium must run at startup
// before any sign or dh call
abstract class Sign {
  static SodiumSumo? _sodium;
  static void bindSodium(SodiumSumo s) => _sodium = s;
  static SodiumSumo get _s {
    final s = _sodium;
    if (s == null) throw StateError('Sign.bindSodium not called');
    return s;
  }

  static Future<Ed25519KeyPair> generateEd25519() async {
    final seed = Csprng.bytes(32);
    return fromSeed(seed);
  }

  static Future<Ed25519KeyPair> fromSeed(Uint8List seed) async {
    if (seed.length != 32) {
      throw ArgumentError('Ed25519 seed must be 32B, got ${seed.length}');
    }
    final secureSeed = SecureKey.fromList(_s, seed);
    try {
      final kp = _s.crypto.sign.seedKeyPair(secureSeed);
      return Ed25519KeyPair(seed: seed, publicKey: kp.publicKey);
    } finally {
      secureSeed.dispose();
    }
  }

  static Future<Uint8List> sign(Ed25519KeyPair kp, Uint8List msg) async {
    final secureSeed = SecureKey.fromList(_s, kp.seed);
    try {
      final full = _s.crypto.sign.seedKeyPair(secureSeed);
      try {
        return _s.crypto.sign.detached(message: msg, secretKey: full.secretKey);
      } finally {
        full.secretKey.dispose();
      }
    } finally {
      secureSeed.dispose();
    }
  }

  static Future<bool> verify(
      Uint8List pubKey, Uint8List msg, Uint8List sig) async {
    if (pubKey.length != 32 || sig.length != 64) return false;
    return _s.crypto.sign
        .verifyDetached(message: msg, signature: sig, publicKey: pubKey);
  }
}

abstract class Kex {
  static SodiumSumo? _sodium;
  static void bindSodium(SodiumSumo s) => _sodium = s;
  static SodiumSumo get _s {
    final s = _sodium;
    if (s == null) throw StateError('Kex.bindSodium not called');
    return s;
  }

  static Future<X25519KeyPair> generateX25519() async {
    // libsodium clamps inside scalarmult.base
    final priv = Csprng.bytes(32);
    return fromSeed(priv);
  }

  static Future<X25519KeyPair> fromSeed(Uint8List priv) async {
    if (priv.length != 32) {
      throw ArgumentError('X25519 scalar must be 32B, got ${priv.length}');
    }
    final secret = SecureKey.fromList(_s, priv);
    try {
      final pub = _s.crypto.scalarmult.base(n: secret);
      return X25519KeyPair(privateKey: priv, publicKey: pub);
    } finally {
      secret.dispose();
    }
  }

  static Future<Uint8List> dh(X25519KeyPair self, Uint8List peerPub) async {
    if (peerPub.length != 32) {
      throw ArgumentError('peer pub must be 32B, got ${peerPub.length}');
    }
    final secret = SecureKey.fromList(_s, self.privateKey);
    try {
      final shared = _s.crypto.scalarmult(n: secret, p: peerPub);
      try {
        return Uint8List.fromList(shared.extractBytes());
      } finally {
        shared.dispose();
      }
    } finally {
      secret.dispose();
    }
  }
}

abstract class Csprng {
  static Uint8List bytes(int n) {
    if (n < 0) throw ArgumentError('n must be >= 0');
    final data = cg.SecretKeyData.random(length: n);
    return Uint8List.fromList(data.bytes);
  }

  static int u32() {
    final b = bytes(4);
    return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24);
  }
}
