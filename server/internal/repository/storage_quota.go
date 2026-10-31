package repository

import (
	"context"
	"errors"

	"github.com/freytastic/miuchio/internal/userlink"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	ErrQuotaExceeded = errors.New("account storage quota exceeded")
	ErrStorageFull   = errors.New("server storage limit reached")
)

// Byte limits, zero turns a limit off
type StorageQuota struct {
	PerUser int64
	Total   int64
}

// Covers every album the account is or was in, pending rows included, so
// photos kept after leaving still count against their uploader
const accountUsageSQL = `
	SELECT
	  (SELECT COALESCE(SUM(m.blob_size + COALESCE(m.thumb_size, 0)), 0)::bigint
	   FROM media m
	   JOIN album_member_identities i ON i.member_token = m.uploader_token
	   WHERE i.user_handle = $1)
	+ (SELECT COALESCE(SUM(a.blob_size), 0)::bigint
	   FROM member_avatars a
	   JOIN album_member_identities i
	     ON i.member_token = a.member_token AND i.album_id = a.album_id
	   WHERE i.user_handle = $1)
	+ (SELECT COALESCE(SUM(c.blob_size), 0)::bigint
	   FROM album_covers c
	   JOIN album_member_identities i ON i.member_token = c.set_by
	   WHERE i.user_handle = $1)`

const totalUsageSQL = `
	SELECT
	  (SELECT COALESCE(SUM(blob_size + COALESCE(thumb_size, 0)), 0)::bigint FROM media)
	+ (SELECT COALESCE(SUM(blob_size), 0)::bigint FROM member_avatars)
	+ (SELECT COALESCE(SUM(blob_size), 0)::bigint FROM album_covers)`

// Runs inside a reservation after the album lock and after any replaced
// pending row is deleted. Every caller takes the account lock second, so the
// two locks always nest in the same order
func (q StorageQuota) admit(ctx context.Context, tx pgx.Tx, memberToken []byte, adding int64) error {
	if q.PerUser > 0 {
		var handle []byte
		if err := tx.QueryRow(ctx,
			`SELECT user_handle FROM album_member_identities WHERE member_token = $1`,
			memberToken,
		).Scan(&handle); err != nil {
			return err
		}
		// Serializes one account's reservations across all its albums
		if _, err := tx.Exec(ctx,
			`SELECT pg_advisory_xact_lock(hashtextextended(encode($1, 'hex'), 0))`, handle,
		); err != nil {
			return err
		}
		var used int64
		if err := tx.QueryRow(ctx, accountUsageSQL, handle).Scan(&used); err != nil {
			return err
		}
		if used+adding > q.PerUser {
			return ErrQuotaExceeded
		}
	}
	if q.Total > 0 {
		// Unlocked, so parallel uploads can overshoot by at most their own sizes
		var used int64
		if err := tx.QueryRow(ctx, totalUsageSQL).Scan(&used); err != nil {
			return err
		}
		if used+adding > q.Total {
			return ErrStorageFull
		}
	}
	return nil
}

type StorageUsage struct {
	UsedBytes  int64
	QuotaBytes int64
}

type StorageRepository struct {
	DB     *pgxpool.Pool
	linker *userlink.Hasher
	quota  StorageQuota
}

func NewStorageRepository(db *pgxpool.Pool, linker *userlink.Hasher, quota StorageQuota) *StorageRepository {
	return &StorageRepository{DB: db, linker: linker, quota: quota}
}

func (r *StorageRepository) Usage(ctx context.Context, userID uuid.UUID) (StorageUsage, error) {
	out := StorageUsage{QuotaBytes: r.quota.PerUser}
	err := r.DB.QueryRow(ctx, accountUsageSQL, r.linker.Hash(userID)).Scan(&out.UsedBytes)
	return out, err
}
