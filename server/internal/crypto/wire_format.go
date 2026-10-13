package crypto

import "fmt"

// Mirrored in client/lib/crypto/wire_format.dart
const (
	VerAesGcm    byte = 0x01
	VerChaPo     byte = 0x02
	VerStreamGcm byte = 0x03

	SegmentSize = 1 << 20

	IkPubLen    = 32
	LkPubLen    = 32
	AlbumIDLen  = 16
	X3dhInfoLen = LkPubLen + LkPubLen + AlbumIDLen
)

// X3dhInfo is LK_pub_A || LK_pub_B || album_id, the X25519 keys from DH1 and
// never the Ed25519 IK keys
func X3dhInfo(lkPubA, lkPubB, albumID []byte) ([]byte, error) {
	if len(lkPubA) != LkPubLen {
		return nil, fmt.Errorf("crypto: lkPubA must be %d bytes, got %d", LkPubLen, len(lkPubA))
	}
	if len(lkPubB) != LkPubLen {
		return nil, fmt.Errorf("crypto: lkPubB must be %d bytes, got %d", LkPubLen, len(lkPubB))
	}
	if len(albumID) != AlbumIDLen {
		return nil, fmt.Errorf("crypto: albumID must be %d bytes (raw UUID), got %d", AlbumIDLen, len(albumID))
	}
	out := make([]byte, X3dhInfoLen)
	copy(out[0:LkPubLen], lkPubA)
	copy(out[LkPubLen:2*LkPubLen], lkPubB)
	copy(out[2*LkPubLen:X3dhInfoLen], albumID)
	return out, nil
}
