package repository

import (
	"bytes"
	"context"
	"errors"
	"time"

	"github.com/freytastic/miuchio/internal/model"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	ErrCoverNotFound  = errors.New("cover not found")
	ErrCoverNotOwned  = errors.New("cover belongs to another upload")
	ErrCoverConfirmed = errors.New("cover already confirmed")
)

type CoverRepository struct {
	DB    *pgxpool.Pool
	quota StorageQuota
}

func NewCoverRepository(db *pgxpool.Pool, quota StorageQuota) *CoverRepository {
	return &CoverRepository{DB: db, quota: quota}
}

// Reserve replaces any pending upload for the album. Only the active admin may
// reserve, rechecked under the album lock
func (r *CoverRepository) Reserve(ctx context.Context, c *model.AlbumCover) error {
	tx, err := r.DB.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	if err := lockAlbumAdmin(ctx, tx, c.AlbumID, c.SetBy); err != nil {
		return err
	}
	if err := requireCurrentEpoch(ctx, tx, c.AlbumID, sealedKeyEpoch(c.KeyCT)); err != nil {
		return err
	}

	var prev struct {
		album     uuid.UUID
		key       *string
		size      *int64
		sha       []byte
		confirmed bool
	}
	err = tx.QueryRow(ctx, `
		SELECT album_id, storage_key, blob_size, blob_sha256, confirmed
		FROM album_covers WHERE cover_id = $1 FOR UPDATE`, c.CoverID,
	).Scan(&prev.album, &prev.key, &prev.size, &prev.sha, &prev.confirmed)
	switch {
	case err == nil && (prev.album != c.AlbumID || prev.key == nil):
		return ErrCoverNotOwned
	case err == nil && prev.confirmed:
		return ErrCoverConfirmed
	case err == nil:
		// A retry of the same bytes may already have completed its PUT
		if prev.size != nil && *prev.size == c.BlobSize && bytes.Equal(prev.sha, c.BlobSHA256) {
			c.StorageKey = *prev.key
		}
	case !errors.Is(err, pgx.ErrNoRows):
		return err
	}

	stale, err := removeStoredObjects(ctx, tx, `
		DELETE FROM album_covers
		WHERE album_id = $1 AND confirmed = FALSE
		RETURNING storage_key`, c.AlbumID)
	if err != nil {
		return err
	}
	if err := unqueueObjectCleanup(ctx, tx, stale, c.StorageKey); err != nil {
		return err
	}
	if err := r.quota.admit(ctx, tx, c.SetBy, c.BlobSize); err != nil {
		return err
	}

	if err := tx.QueryRow(ctx, `
		INSERT INTO album_covers (
			cover_id, album_id, set_by, storage_key, blob_size, blob_sha256, key_ct
		) VALUES ($1, $2, $3, $4, $5, $6, $7)
		RETURNING created_at`,
		c.CoverID, c.AlbumID, c.SetBy, c.StorageKey, c.BlobSize, c.BlobSHA256, c.KeyCT,
	).Scan(&c.CreatedAt); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// Get returns one uploaded cover in the album regardless of confirmed state
func (r *CoverRepository) Get(ctx context.Context, albumID, coverID uuid.UUID) (*model.AlbumCover, error) {
	var c model.AlbumCover
	err := r.DB.QueryRow(ctx, `
		SELECT cover_id, album_id, set_by, storage_key, blob_size,
		       blob_sha256, key_ct, confirmed, created_at
		FROM album_covers
		WHERE cover_id = $1 AND album_id = $2 AND storage_key IS NOT NULL`,
		coverID, albumID,
	).Scan(&c.CoverID, &c.AlbumID, &c.SetBy, &c.StorageKey, &c.BlobSize,
		&c.BlobSHA256, &c.KeyCT, &c.Confirmed, &c.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrCoverNotFound
	}
	if err != nil {
		return nil, err
	}
	return &c, nil
}

// Confirm swaps the pending upload in and returns the replaced object keys,
// already queued for cleanup. storageKey is the object the caller checked, so
// a retry that re-reserved the same id with other bytes is not confirmed
// unchecked. Confirming the current cover again is a no op
func (r *CoverRepository) Confirm(ctx context.Context, albumID uuid.UUID, setBy []byte, coverID uuid.UUID, storageKey string) ([]string, error) {
	tx, err := r.DB.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	if err := lockAlbumAdmin(ctx, tx, albumID, setBy); err != nil {
		return nil, err
	}

	var confirmed bool
	var keyCT []byte
	err = tx.QueryRow(ctx, `
		SELECT confirmed, key_ct FROM album_covers
		WHERE cover_id = $1 AND album_id = $2 AND storage_key = $3
		FOR UPDATE`,
		coverID, albumID, storageKey,
	).Scan(&confirmed, &keyCT)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrCoverNotFound
	}
	if err != nil {
		return nil, err
	}
	if confirmed {
		return nil, tx.Commit(ctx)
	}
	// A revoke or rotation may have committed since the reservation
	if err := requireCurrentEpoch(ctx, tx, albumID, sealedKeyEpoch(keyCT)); err != nil {
		return nil, err
	}

	replaced, err := retireCovers(ctx, tx, albumID, &coverID)
	if err != nil {
		return nil, err
	}
	// The row lock keeps stale cleanup off it, the count proves that held
	tag, err := tx.Exec(ctx,
		`UPDATE album_covers SET confirmed = TRUE
		 WHERE cover_id = $1 AND storage_key = $2 AND confirmed = FALSE`,
		coverID, storageKey)
	if err != nil {
		return nil, err
	}
	if tag.RowsAffected() != 1 {
		return nil, ErrCoverNotFound
	}
	return replaced, tx.Commit(ctx)
}

// SetMedia makes one of the album's confirmed photos the cover. Nil goes back
// to the newest photo. Returns the object keys of any uploaded cover it replaced
func (r *CoverRepository) SetMedia(ctx context.Context, albumID uuid.UUID, setBy []byte, mediaID *uuid.UUID) ([]string, error) {
	tx, err := r.DB.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	if err := lockAlbumAdmin(ctx, tx, albumID, setBy); err != nil {
		return nil, err
	}
	if mediaID != nil {
		var ok bool
		if err := tx.QueryRow(ctx, `
			SELECT EXISTS (
			    SELECT 1 FROM media
			    WHERE id = $1 AND album_id = $2 AND confirmed = TRUE
			      AND thumb_wrap_nonce IS NOT NULL)`, *mediaID, albumID,
		).Scan(&ok); err != nil {
			return nil, err
		}
		if !ok {
			return nil, ErrMediaNotFound
		}
	}

	replaced, err := retireCovers(ctx, tx, albumID, nil)
	if err != nil {
		return nil, err
	}
	if mediaID != nil {
		if _, err := tx.Exec(ctx, `
			INSERT INTO album_covers (cover_id, album_id, set_by, media_id, confirmed)
			VALUES ($1, $2, $3, $4, TRUE)`,
			uuid.New(), albumID, setBy, *mediaID,
		); err != nil {
			return nil, err
		}
	}
	return replaced, tx.Commit(ctx)
}

// DropPending retires the one unconfirmed upload whose object failed
// verification, never a newer reservation under the same id
func (r *CoverRepository) DropPending(ctx context.Context, albumID, coverID uuid.UUID, storageKey string) ([]string, error) {
	return r.removeInTx(ctx, `
		DELETE FROM album_covers
		WHERE cover_id = $1 AND album_id = $2 AND storage_key = $3
		  AND confirmed = FALSE
		RETURNING storage_key`, coverID, albumID, storageKey)
}

// QueueStalePending retires abandoned uploads. SKIP LOCKED leaves rows that a
// confirm is holding
func (r *CoverRepository) QueueStalePending(ctx context.Context, before time.Time, limit int) ([]string, error) {
	if limit <= 0 {
		return nil, nil
	}
	return r.removeInTx(ctx, `
		WITH stale AS (
			SELECT cover_id FROM album_covers
			WHERE confirmed = FALSE AND created_at <= $1
			ORDER BY created_at, cover_id
			LIMIT $2
			FOR UPDATE SKIP LOCKED
		)
		DELETE FROM album_covers c
		USING stale
		WHERE c.cover_id = stale.cover_id AND c.confirmed = FALSE
		RETURNING c.storage_key`, before, limit)
}

func (r *CoverRepository) removeInTx(ctx context.Context, sql string, args ...any) ([]string, error) {
	tx, err := r.DB.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	keys, err := removeStoredObjects(ctx, tx, sql, args...)
	if err != nil {
		return nil, err
	}
	return keys, tx.Commit(ctx)
}

// retireCovers drops every cover row of the album except keep, queueing the
// objects of uploaded ones
func retireCovers(ctx context.Context, tx pgx.Tx, albumID uuid.UUID, keep *uuid.UUID) ([]string, error) {
	keys, err := removeStoredObjects(ctx, tx, `
		DELETE FROM album_covers
		WHERE album_id = $1 AND storage_key IS NOT NULL
		  AND ($2::uuid IS NULL OR cover_id <> $2)
		RETURNING storage_key`, albumID, keep)
	if err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx,
		`DELETE FROM album_covers WHERE album_id = $1 AND media_id IS NOT NULL`, albumID,
	); err != nil {
		return nil, err
	}
	return keys, nil
}

func lockAlbumAdmin(ctx context.Context, tx pgx.Tx, albumID uuid.UUID, memberToken []byte) error {
	if err := lockAlbum(ctx, tx, albumID); err != nil {
		return err
	}
	var role string
	var revoked bool
	err := tx.QueryRow(ctx,
		`SELECT role, revoked_at IS NOT NULL FROM album_members
		 WHERE album_id = $1 AND member_token = $2`,
		albumID, memberToken,
	).Scan(&role, &revoked)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && revoked) {
		return ErrCallerRevoked
	}
	if err != nil {
		return err
	}
	if role != "admin" {
		return ErrNotAlbumAdmin
	}
	return nil
}

// Nullable columns of a LEFT JOIN on the album's current cover
type coverColumns struct {
	id      *uuid.UUID
	setBy   []byte
	mediaID *uuid.UUID
	size    *int64
	sha     []byte
	keyCT   []byte
}

func (c coverColumns) ref() *model.CoverRef {
	if c.id == nil {
		return nil
	}
	ref := &model.CoverRef{CoverID: *c.id, SetBy: c.setBy, MediaID: c.mediaID}
	if c.mediaID == nil {
		if c.size == nil {
			return nil
		}
		ref.BlobSize, ref.BlobSHA256, ref.KeyCT = *c.size, c.sha, c.keyCT
	}
	return ref
}
