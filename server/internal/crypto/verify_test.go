package crypto

import (
	"crypto/ed25519"
	"crypto/rand"
	"testing"
)

func TestVerifyEd25519_ValidSignature(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	msg := []byte("test message")
	sig := ed25519.Sign(priv, msg)
	if err := VerifyEd25519(pub, msg, sig); err != nil {
		t.Errorf("expected valid, got: %v", err)
	}
}

func TestVerifyEd25519_RejectsTamperedMessage(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	sig := ed25519.Sign(priv, []byte("original"))
	if err := VerifyEd25519(pub, []byte("tampered"), sig); err == nil {
		t.Error("expected error on tampered message, got nil")
	}
}

func TestVerifyEd25519_RejectsTamperedSignature(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	msg := []byte("test")
	sig := ed25519.Sign(priv, msg)
	sig[0] ^= 0x01
	if err := VerifyEd25519(pub, msg, sig); err == nil {
		t.Error("expected error on tampered signature, got nil")
	}
}

func TestVerifyEd25519_RejectsWrongSizeKey(t *testing.T) {
	if err := VerifyEd25519(make([]byte, 31), nil, make([]byte, 64)); err == nil {
		t.Error("expected error for wrong key size")
	}
}

func TestVerifyEd25519_RejectsWrongSizeSig(t *testing.T) {
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	if err := VerifyEd25519(pub, nil, make([]byte, 63)); err == nil {
		t.Error("expected error for wrong signature size")
	}
}

func TestConstantTimeEq(t *testing.T) {
	tests := []struct {
		name   string
		a, b   []byte
		expect bool
	}{
		{"equal", []byte{1, 2, 3}, []byte{1, 2, 3}, true},
		{"different content", []byte{1, 2, 3}, []byte{1, 2, 4}, false},
		{"different length", []byte{1, 2, 3}, []byte{1, 2}, false},
		{"both empty", []byte{}, []byte{}, true},
		{"one empty", []byte{}, []byte{1}, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := ConstantTimeEq(tc.a, tc.b); got != tc.expect {
				t.Errorf("got %v, want %v", got, tc.expect)
			}
		})
	}
}
