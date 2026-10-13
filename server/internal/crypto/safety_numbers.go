package crypto

import (
	"crypto/sha256"
	"fmt"
	"math/big"
	"strings"
)

const safetyNumberDigits = 30

// Zero padding to 78 digits (2^256 < 10^78) keeps the digit positions fixed
// even when the hash has leading zero bytes
const safetyNumberPad = 78

// SafetyNumber is the first 30 decimal digits of
// SHA256(sort(IK_pub_A, IK_pub_B) || album_id). Must match the Dart side
func SafetyNumber(ikPubA, ikPubB, albumID []byte) (string, error) {
	if len(ikPubA) != IkPubLen {
		return "", fmt.Errorf("crypto: ikPubA must be %d bytes, got %d", IkPubLen, len(ikPubA))
	}
	if len(ikPubB) != IkPubLen {
		return "", fmt.Errorf("crypto: ikPubB must be %d bytes, got %d", IkPubLen, len(ikPubB))
	}
	if len(albumID) != AlbumIDLen {
		return "", fmt.Errorf("crypto: albumID must be %d bytes, got %d", AlbumIDLen, len(albumID))
	}
	lo, hi := ikPubA, ikPubB
	if compareBytes(ikPubA, ikPubB) > 0 {
		lo, hi = ikPubB, ikPubA
	}
	pre := make([]byte, 0, IkPubLen+IkPubLen+AlbumIDLen)
	pre = append(pre, lo...)
	pre = append(pre, hi...)
	pre = append(pre, albumID...)
	d := sha256.Sum256(pre)

	n := new(big.Int).SetBytes(d[:]).String()
	if len(n) < safetyNumberPad {
		n = strings.Repeat("0", safetyNumberPad-len(n)) + n
	}
	return n[:safetyNumberDigits], nil
}

// SafetyNumberFormatted groups the digits in fives
func SafetyNumberFormatted(ikPubA, ikPubB, albumID []byte) (string, error) {
	d, err := SafetyNumber(ikPubA, ikPubB, albumID)
	if err != nil {
		return "", err
	}
	var sb strings.Builder
	for i := 0; i < len(d); i += 5 {
		if i > 0 {
			sb.WriteByte(' ')
		}
		sb.WriteString(d[i : i+5])
	}
	return sb.String(), nil
}

func compareBytes(a, b []byte) int {
	n := len(a)
	if len(b) < n {
		n = len(b)
	}
	for i := 0; i < n; i++ {
		if a[i] != b[i] {
			return int(a[i]) - int(b[i])
		}
	}
	return len(a) - len(b)
}
