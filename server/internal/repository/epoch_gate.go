package repository

import (
	"context"
	"encoding/binary"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// requireCurrentEpoch refuses content sealed under anything but the album's
// newest key, or while a revoke still owes a rotation, so a departed member's
// old key never opens anything new. Callers hold the album lock, so neither
// can change before they commit
func requireCurrentEpoch(ctx context.Context, tx pgx.Tx, albumID uuid.UUID, epoch int) error {
	var pending bool
	if err := tx.QueryRow(ctx,
		`SELECT `+RotationRequiredExpr("$1"), albumID,
	).Scan(&pending); err != nil {
		return err
	}
	if pending {
		return ErrPendingRotation
	}
	var cur int
	if err := tx.QueryRow(ctx,
		`SELECT COALESCE(MAX(epoch), -1) FROM album_epochs WHERE album_id = $1`,
		albumID,
	).Scan(&cur); err != nil {
		return err
	}
	if cur < 0 {
		return ErrNoEpoch
	}
	if epoch != cur {
		return ErrEpochMismatch
	}
	return nil
}

// Avatar and cover keys start with u32_be(epoch). The epoch is also bound
// into the key's AAD, so a forged prefix only yields a key nobody can open
func sealedKeyEpoch(keyCT []byte) int {
	if len(keyCT) < 4 {
		return -1
	}
	return int(binary.BigEndian.Uint32(keyCT[:4]))
}
