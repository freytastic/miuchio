// Package userlink keeps album_member_identities from linking user_id to
// member_token in the clear. Two subkeys, both HKDF derived from
// MIUCHIO_USER_LINK_KEY, cover the two access patterns:

//	Hash(user_id)              32B HMAC handle, indexed, for "which albums is
//	                           this user in"
//	Seal(user_id, token)       32B AES-GCM blob with a nonce derived from the
//	                           random token, for "which user owns this token"

// Without the live key a leaked database does not reveal which user owns a
// token, though the deterministic handles still correlate one user's rows. A
// compromised live server has the key, so this is encryption at rest, not zero
// knowledge
package userlink

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"

	"github.com/google/uuid"
	"golang.org/x/crypto/hkdf"
)

const (
	// HandleLen : SHA-256 output, fixed
	HandleLen = 32
	// SealedLen : AES-GCM(16B plaintext) = 16B ct + 16B tag = 32B fixed
	SealedLen = 32
)

// info strings for HKDF subkey derivation. Changing either bricks every
// existing row that was sealed under the old subkey
var (
	infoHandle = []byte("user-handle-v1")
	infoEnc    = []byte("user-id-enc-v1")
	// nonce is derived from member_token via SHA256 : the prefix domain
	// separates this nonce from any other use of the member_token bytes
	nonceInfo = []byte("user-id-enc-nonce-v1")
)

type Hasher struct {
	handleKey []byte // 32B for HMAC-SHA256
	gcm       cipher.AEAD
}

// New returns an error for a master key under 32 bytes or a failed HKDF or AES
// setup
func New(masterKey []byte) (*Hasher, error) {
	if len(masterKey) < 32 {
		return nil, errors.New("userlink: master key must be >= 32 bytes")
	}
	handleKey := make([]byte, 32)
	if _, err := io.ReadFull(hkdf.New(sha256.New, masterKey, nil, infoHandle), handleKey); err != nil {
		return nil, fmt.Errorf("userlink: derive handle key: %w", err)
	}
	encKey := make([]byte, 32)
	if _, err := io.ReadFull(hkdf.New(sha256.New, masterKey, nil, infoEnc), encKey); err != nil {
		return nil, fmt.Errorf("userlink: derive enc key: %w", err)
	}
	block, err := aes.NewCipher(encKey)
	if err != nil {
		return nil, fmt.Errorf("userlink: aes new cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("userlink: aes-gcm: %w", err)
	}
	return &Hasher{handleKey: handleKey, gcm: gcm}, nil
}

// Hash returns the 32B deterministic handle for user_id. Same input always
// yields the same output (required for indexed lookups)
func (h *Hasher) Hash(userID uuid.UUID) []byte {
	mac := hmac.New(sha256.New, h.handleKey)
	mac.Write(userID[:])
	return mac.Sum(nil)
}

// Seal returns the encrypted user_id blob for storage in amid.user_id_enc
// Nonce is derived from member_token : the input must be at least 12 bytes of
// CSPRNG output (member_token is 32B random by construction). Two rows with
// the same member_token would reuse the same nonce, but member_token is a PK
// so duplicates are structurally impossible
func (h *Hasher) Seal(userID uuid.UUID, memberToken []byte) ([]byte, error) {
	if len(memberToken) < 12 {
		return nil, errors.New("userlink: memberToken must be >= 12 bytes")
	}
	nonce := deriveNonce(memberToken)
	return h.gcm.Seal(nil, nonce, userID[:], nil), nil
}

// Open reverses Seal. Returns ErrInvalidSeal if the ciphertext doesnt verify
// (corrupt row, wrong key, or wrong member_token)
func (h *Hasher) Open(sealed, memberToken []byte) (uuid.UUID, error) {
	if len(memberToken) < 12 {
		return uuid.Nil, errors.New("userlink: memberToken must be >= 12 bytes")
	}
	nonce := deriveNonce(memberToken)
	pt, err := h.gcm.Open(nil, nonce, sealed, nil)
	if err != nil {
		return uuid.Nil, ErrInvalidSeal
	}
	if len(pt) != 16 {
		return uuid.Nil, ErrInvalidSeal
	}
	var u uuid.UUID
	copy(u[:], pt)
	return u, nil
}

var ErrInvalidSeal = errors.New("userlink: invalid sealed user_id")

func deriveNonce(memberToken []byte) []byte {
	h := sha256.New()
	h.Write(nonceInfo)
	h.Write(memberToken)
	sum := h.Sum(nil)
	return sum[:12]
}
