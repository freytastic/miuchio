package repository

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var ErrReportNotFound = errors.New("report not found")

type ReportInput struct {
	AlbumID       uuid.UUID
	MediaID       *uuid.UUID
	MediaUpload   *uuid.UUID
	Kind          string
	SubjectToken  []byte
	ReporterToken []byte
	Sealed        []byte
}

type Report struct {
	ID            uuid.UUID
	AlbumID       uuid.UUID
	MediaID       *uuid.UUID
	MediaUpload   *uuid.UUID
	Kind          string
	SubjectToken  []byte
	SubjectEnc    []byte
	ReporterToken []byte
	ReporterEnc   []byte
	Sealed        []byte
	CreatedAt     time.Time
	ResolvedAt    *time.Time
	Resolution    *string
}

type ReportRepository struct {
	DB *pgxpool.Pool
}

func NewReportRepository(db *pgxpool.Pool) *ReportRepository {
	return &ReportRepository{DB: db}
}

// Uploader resolves a photo's uploader and upload on the server, so a
// reporter cannot name someone else
func (r *ReportRepository) Uploader(ctx context.Context, albumID, mediaID uuid.UUID) ([]byte, uuid.UUID, error) {
	var token []byte
	var upload uuid.UUID
	err := r.DB.QueryRow(ctx,
		`SELECT uploader_token, reservation_id FROM media
		 WHERE id = $1 AND album_id = $2 AND confirmed = TRUE`,
		mediaID, albumID,
	).Scan(&token, &upload)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, uuid.Nil, ErrMediaNotFound
	}
	return token, upload, err
}

// reportedMedia matches only the upload the report was made about, by the
// member it names
const reportedMedia = `id = $1 AND album_id = $2 AND reservation_id = $3 AND uploader_token = $4`

// StoredThumb is where the reported photo's encrypted thumbnail lives, for
// checking a report's attachment against what the uploader really sent
func (r *ReportRepository) StoredThumb(ctx context.Context, rep Report) (string, []byte, error) {
	if rep.MediaID == nil || rep.MediaUpload == nil {
		return "", nil, ErrMediaNotFound
	}
	var key *string
	var sha []byte
	err := r.DB.QueryRow(ctx,
		`SELECT thumb_key, thumb_sha256 FROM media WHERE confirmed = TRUE AND `+reportedMedia,
		*rep.MediaID, rep.AlbumID, *rep.MediaUpload, rep.SubjectToken,
	).Scan(&key, &sha)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && key == nil) {
		return "", nil, ErrMediaNotFound
	}
	if err != nil {
		return "", nil, err
	}
	return *key, sha, nil
}

// Copies both sealed user links, so the report outlives the album
func (r *ReportRepository) Create(ctx context.Context, in ReportInput) (uuid.UUID, error) {
	var id uuid.UUID
	err := r.DB.QueryRow(ctx,
		`INSERT INTO reports (album_id, media_id, media_upload, kind, subject_token, subject_enc,
		                      reporter_token, reporter_enc, sealed)
		 SELECT $1, $2, $7, $3, s.member_token, s.user_id_enc, p.member_token, p.user_id_enc, $6
		 FROM album_member_identities s, album_member_identities p
		 WHERE s.album_id = $1 AND s.member_token = $4
		   AND p.album_id = $1 AND p.member_token = $5
		 RETURNING id`,
		in.AlbumID, in.MediaID, in.Kind, in.SubjectToken, in.ReporterToken, in.Sealed, in.MediaUpload,
	).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return uuid.Nil, ErrMemberNotFound
	}
	return id, err
}

const reportColumns = `id, album_id, media_id, media_upload, kind, subject_token, subject_enc,
	reporter_token, reporter_enc, sealed, created_at, resolved_at, resolution`

func scanReport(row pgx.Row) (Report, error) {
	var rep Report
	err := row.Scan(&rep.ID, &rep.AlbumID, &rep.MediaID, &rep.MediaUpload, &rep.Kind, &rep.SubjectToken, &rep.SubjectEnc,
		&rep.ReporterToken, &rep.ReporterEnc, &rep.Sealed, &rep.CreatedAt, &rep.ResolvedAt, &rep.Resolution)
	return rep, err
}

func (r *ReportRepository) Get(ctx context.Context, id uuid.UUID) (Report, error) {
	rep, err := scanReport(r.DB.QueryRow(ctx, `SELECT `+reportColumns+` FROM reports WHERE id = $1`, id))
	if errors.Is(err, pgx.ErrNoRows) {
		return Report{}, ErrReportNotFound
	}
	return rep, err
}

func (r *ReportRepository) List(ctx context.Context, includeResolved bool) ([]Report, error) {
	rows, err := r.DB.Query(ctx,
		`SELECT `+reportColumns+` FROM reports
		 WHERE $1 OR resolved_at IS NULL ORDER BY created_at`,
		includeResolved,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Report
	for rows.Next() {
		rep, err := scanReport(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, rep)
	}
	return out, rows.Err()
}

// Resolve records the decision and its audit row together
func (r *ReportRepository) Resolve(ctx context.Context, id uuid.UUID, resolution string) error {
	return r.inTx(ctx, func(tx pgx.Tx) error { return resolve(ctx, tx, id, resolution) })
}

// RemoveReportedMedia deletes the photo on the same path as its uploader would,
// queueing its objects for the cleanup sweep
func (r *ReportRepository) RemoveReportedMedia(ctx context.Context, rep Report) error {
	if rep.MediaID == nil || rep.MediaUpload == nil {
		return ErrMediaNotFound
	}
	return r.inTx(ctx, func(tx pgx.Tx) error {
		if err := lockAlbum(ctx, tx, rep.AlbumID); err != nil {
			return err
		}
		out, err := removeMedia(ctx, tx,
			`DELETE FROM media WHERE `+reportedMedia+`
			 RETURNING id, storage_key, thumb_key`,
			*rep.MediaID, rep.AlbumID, *rep.MediaUpload, rep.SubjectToken)
		if err != nil {
			return err
		}
		if len(out.MediaIDs) == 0 {
			return ErrMediaNotFound
		}
		return resolve(ctx, tx, rep.ID, "removed")
	})
}

// Suspend keeps the account and its data but ends every session, and the
// session lookups refuse it from here on
func (r *ReportRepository) Suspend(ctx context.Context, reportID, userID uuid.UUID) error {
	return r.inTx(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx,
			`UPDATE users SET suspended_at = COALESCE(suspended_at, now()) WHERE id = $1`, userID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrUserNotFound
		}
		if _, err := tx.Exec(ctx, `DELETE FROM sessions WHERE user_id = $1`, userID); err != nil {
			return err
		}
		return resolve(ctx, tx, reportID, "suspended")
	})
}

type Suspension struct {
	MiuchioID   string
	SuspendedAt time.Time
}

func (r *ReportRepository) ListSuspended(ctx context.Context) ([]Suspension, error) {
	rows, err := r.DB.Query(ctx,
		`SELECT miuchio_id, suspended_at FROM users WHERE suspended_at IS NOT NULL ORDER BY suspended_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Suspension
	for rows.Next() {
		var s Suspension
		if err := rows.Scan(&s.MiuchioID, &s.SuspendedAt); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// Unsuspend goes by Miuchio ID, so it still works once the report is purged
func (r *ReportRepository) Unsuspend(ctx context.Context, miuchioID string) error {
	return r.inTx(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx,
			`UPDATE users SET suspended_at = NULL WHERE miuchio_id = $1 AND suspended_at IS NOT NULL`, miuchioID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrUserNotFound
		}
		return LogModeration(ctx, tx, nil, "unsuspended")
	})
}

func (r *ReportRepository) inTx(ctx context.Context, fn func(pgx.Tx) error) error {
	tx, err := r.DB.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func resolve(ctx context.Context, tx pgx.Tx, id uuid.UUID, resolution string) error {
	tag, err := tx.Exec(ctx,
		`UPDATE reports SET resolved_at = now(), resolution = $2 WHERE id = $1`, id, resolution)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrReportNotFound
	}
	return LogModeration(ctx, tx, &id, resolution)
}

func LogModeration(ctx context.Context, tx pgx.Tx, reportID *uuid.UUID, action string) error {
	_, err := tx.Exec(ctx,
		`INSERT INTO moderation_actions (report_id, action) VALUES ($1, $2)`, reportID, action)
	return err
}

// Purge drops decided reports after one window and undecided ones after a
// longer one, so evidence never stays indefinitely
func (r *ReportRepository) Purge(ctx context.Context, resolvedBefore, openBefore time.Time) (int64, error) {
	tag, err := r.DB.Exec(ctx,
		`DELETE FROM reports
		 WHERE (resolved_at IS NOT NULL AND resolved_at < $1)
		    OR (resolved_at IS NULL AND created_at < $2)`,
		resolvedBefore, openBefore)
	return tag.RowsAffected(), err
}
