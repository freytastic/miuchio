package repository

import (
	"context"
	"encoding/binary"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var ErrBlockNotFound = errors.New("block not found")

type Block struct {
	ID        uuid.UUID
	CreatedAt time.Time
}

type BlockRepository struct {
	DB *pgxpool.Pool
}

func NewBlockRepository(db *pgxpool.Pool) *BlockRepository {
	return &BlockRepository{DB: db}
}

// Blocking and joining both take this lock, so a block committed first is
// always seen by the join that follows it
func LockBlockPair(ctx context.Context, tx pgx.Tx, pair []byte) error {
	_, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, int64(binary.BigEndian.Uint64(pair)))
	return err
}

// PairBlocked must run after LockBlockPair in the same transaction
func PairBlocked(ctx context.Context, tx pgx.Tx, pair []byte) (bool, error) {
	var blocked bool
	err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM blocks WHERE pair_hash = $1)`, pair).Scan(&blocked)
	return blocked, err
}

// Create is idempotent and returns the existing block on a repeat
func (r *BlockRepository) Create(ctx context.Context, blocker, pair []byte) (Block, error) {
	tx, err := r.DB.Begin(ctx)
	if err != nil {
		return Block{}, err
	}
	defer tx.Rollback(ctx)
	if err := LockBlockPair(ctx, tx, pair); err != nil {
		return Block{}, err
	}
	var b Block
	err = tx.QueryRow(ctx,
		`INSERT INTO blocks (blocker_hash, pair_hash) VALUES ($1, $2)
		 ON CONFLICT (blocker_hash, pair_hash) DO UPDATE SET blocker_hash = EXCLUDED.blocker_hash
		 RETURNING id, created_at`,
		blocker, pair,
	).Scan(&b.ID, &b.CreatedAt)
	if err != nil {
		return Block{}, err
	}
	return b, tx.Commit(ctx)
}

func (r *BlockRepository) List(ctx context.Context, blocker []byte) ([]Block, error) {
	rows, err := r.DB.Query(ctx,
		`SELECT id, created_at FROM blocks WHERE blocker_hash = $1 ORDER BY created_at DESC`,
		blocker,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Block{}
	for rows.Next() {
		var b Block
		if err := rows.Scan(&b.ID, &b.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

func (r *BlockRepository) Delete(ctx context.Context, blocker []byte, id uuid.UUID) error {
	tag, err := r.DB.Exec(ctx, `DELETE FROM blocks WHERE id = $1 AND blocker_hash = $2`, id, blocker)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrBlockNotFound
	}
	return nil
}
