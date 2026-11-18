# Cryptographic core

Primitives, the X3DH handshake and the wire formats. A mistake here does not show up as an error: a wrong byte order or a reused nonce still produces ciphertext, it just stops being safe. Open an issue before changing anything in this folder.

## Rules

- Pure Dart only, with no `package:flutter` imports.
- No I/O: no HTTP, no storage and no logging. Bytes in, bytes out.
- Output bytes are pinned by known answer tests in `test_vectors/crypto_kat.json`, which the Go server must match too. Never edit a vector to make a test pass. If your change alters the bytes, find out why first.
- Never log secret material. Keys, plaintexts and intermediate values must not reach `print`, `debugPrint` or any other output.

## Where other code goes

A helper that a screen or the data layer needs usually belongs in `domain/` or `data/`, not here.
