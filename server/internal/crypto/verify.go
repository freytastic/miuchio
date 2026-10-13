package crypto

import (
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
)

// VerifyEd25519 reports bad lengths separately from a bad signature
func VerifyEd25519(pub ed25519.PublicKey, msg, sig []byte) error {
	if len(pub) != ed25519.PublicKeySize {
		return errors.New("crypto: Ed25519 public key must be 32 bytes")
	}
	if len(sig) != ed25519.SignatureSize {
		return errors.New("crypto: Ed25519 signature must be 64 bytes")
	}
	if !ed25519.Verify(pub, msg, sig) {
		return errors.New("crypto: Ed25519 signature verification failed")
	}
	return nil
}

func SHA256(b []byte) [32]byte {
	return sha256.Sum256(b)
}

// ConstantTimeEq returns false for different lengths
func ConstantTimeEq(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	return subtle.ConstantTimeCompare(a, b) == 1
}
