// Package crypto mirrors the client's constants and verifiers. The server
// never decrypts, it only checks signatures and hashes, and every byte here
// must match client/lib/crypto
package crypto

// Pinned against the Dart values by the KAT tests
var (
	SaltX3dh          = []byte("vault-x3dh-v1")
	SaltInvite        = []byte("invite-v1")
	SaltSegNonce      = []byte("seg-nonce-v1")
	SaltKeyConfirm    = []byte("key-confirm-v1")
	SaltManifest      = []byte("manifest-v1")
	SaltSpkRotate     = []byte("rotate-spk-v1")
	SaltEpochSet      = []byte("epoch-set-v1")
	SaltPromote       = []byte("promote-v1")
	SaltJoinComplete  = []byte("join-complete-v1")
	SaltAlbumNameHint = []byte("album-name-v1")
)
