package service

import (
	"context"
	"encoding/base64"
	"errors"
	"log/slog"
	"time"

	"github.com/freytastic/miuchio/internal/apierr"
	"github.com/freytastic/miuchio/internal/model"
	"github.com/freytastic/miuchio/internal/repository"
	"github.com/freytastic/miuchio/internal/ws"
	"github.com/google/uuid"
)

// Clients pad every cover to one fixed size, this is only the ceiling
const MaxCoverBytes int64 = 512 * 1024

type CoverStore interface {
	Reserve(ctx context.Context, c *model.AlbumCover) error
	Get(ctx context.Context, albumID, coverID uuid.UUID) (*model.AlbumCover, error)
	Confirm(ctx context.Context, albumID uuid.UUID, setBy []byte, coverID uuid.UUID, storageKey string) ([]string, error)
	SetMedia(ctx context.Context, albumID uuid.UUID, setBy []byte, mediaID *uuid.UUID) ([]string, error)
	DropPending(ctx context.Context, albumID, coverID uuid.UUID, storageKey string) ([]string, error)
	QueueStalePending(ctx context.Context, before time.Time, limit int) ([]string, error)
}

type CoverService struct {
	repo     CoverStore
	s3       ObjectStore
	cleaner  ObjectCleaner
	notifier Notifier
	lookup   MemberLookup
}

func NewCoverService(repo CoverStore, s3 ObjectStore, cleaner ObjectCleaner, notifier Notifier, lookup MemberLookup) *CoverService {
	return &CoverService{repo: repo, s3: s3, cleaner: cleaner, notifier: notifier, lookup: lookup}
}

type CoverUploadInput struct {
	CoverID    uuid.UUID
	BlobSize   int64
	BlobSHA256 []byte
	KeyCT      []byte
}

func (s *CoverService) RequestUploadURL(ctx context.Context, albumID uuid.UUID, memberToken []byte, in CoverUploadInput) (*PresignedUpload, error) {
	if in.CoverID == uuid.Nil {
		return nil, apierr.Validation("cover_id is required")
	}
	if in.BlobSize <= 0 || in.BlobSize > MaxCoverBytes {
		return nil, apierr.Validation("blob_size is out of range for a cover")
	}
	if len(in.BlobSHA256) != sha256Len {
		return nil, apierr.Validation("blob_sha256 must be 32 bytes")
	}
	if len(in.KeyCT) != avatarKeyCTLen {
		return nil, apierr.Validation("key_ct has the wrong length")
	}
	key, err := newStorageKey()
	if err != nil {
		return nil, apierr.Internal("failed to mint storage key").WithCause(err)
	}
	row := &model.AlbumCover{
		CoverID:    in.CoverID,
		AlbumID:    albumID,
		SetBy:      memberToken,
		StorageKey: key,
		BlobSize:   in.BlobSize,
		BlobSHA256: in.BlobSHA256,
		KeyCT:      in.KeyCT,
	}
	if err := s.repo.Reserve(ctx, row); err != nil {
		switch {
		case errors.Is(err, repository.ErrCoverNotOwned):
			return nil, apierr.Forbidden("cover_id is used by another upload")
		case errors.Is(err, repository.ErrCoverConfirmed):
			return nil, apierr.Conflict("cover is already confirmed")
		case errors.Is(err, repository.ErrQuotaExceeded):
			return nil, apierr.QuotaExceeded("account storage is full")
		case errors.Is(err, repository.ErrStorageFull):
			return nil, apierr.StorageFull("server storage is full")
		}
		return nil, coverErr(err, "failed to reserve cover")
	}
	sha := base64.StdEncoding.EncodeToString(in.BlobSHA256)
	pre, err := s.s3.GetPresignedUploadURLWithChecksum(ctx, row.StorageKey,
		"application/octet-stream", in.BlobSize, sha, PresignTTL)
	if err != nil {
		return nil, apierr.Internal("failed to presign cover upload").WithCause(err)
	}
	return pre, nil
}

// Confirm checks the uploaded object before it replaces the current cover
func (s *CoverService) Confirm(ctx context.Context, albumID, callerUserID uuid.UUID, memberToken []byte, coverID uuid.UUID) error {
	row, err := s.repo.Get(ctx, albumID, coverID)
	if err != nil {
		if errors.Is(err, repository.ErrCoverNotFound) {
			return apierr.NotFound("cover upload not found")
		}
		return apierr.Internal("failed to read cover").WithCause(err)
	}
	if !row.Confirmed {
		size, sha, err := s.s3.HeadObject(ctx, row.StorageKey)
		if err != nil {
			return apierr.Validation("cover upload not found on storage").WithCause(err)
		}
		want := base64.StdEncoding.EncodeToString(row.BlobSHA256)
		if size != row.BlobSize || (sha != "" && sha != want) {
			s.drop(ctx, albumID, coverID, row.StorageKey)
			return apierr.Validation("uploaded cover does not match its reservation ; pending row dropped")
		}
	}
	replaced, err := s.repo.Confirm(ctx, albumID, memberToken, coverID, row.StorageKey)
	if err != nil {
		if errors.Is(err, repository.ErrCoverNotFound) {
			return apierr.Conflict("cover reservation is no longer current ; re-upload")
		}
		return coverErr(err, "failed to confirm cover")
	}
	s.cleanup(ctx, replaced)
	if !row.Confirmed {
		emitToOthers(s.lookup, s.notifier, albumID, callerUserID, ws.EventAlbumUpdated,
			map[string]any{"album_id": albumID.String()})
	}
	return nil
}

// SetMedia picks one of the album's photos as its cover, nil the newest
func (s *CoverService) SetMedia(ctx context.Context, albumID, callerUserID uuid.UUID, memberToken []byte, mediaID *uuid.UUID) error {
	replaced, err := s.repo.SetMedia(ctx, albumID, memberToken, mediaID)
	if err != nil {
		if errors.Is(err, repository.ErrMediaNotFound) {
			return apierr.Validation("that photo is not in this album")
		}
		return coverErr(err, "failed to set cover")
	}
	s.cleanup(ctx, replaced)
	emitToOthers(s.lookup, s.notifier, albumID, callerUserID, ws.EventAlbumUpdated,
		map[string]any{"album_id": albumID.String()})
	return nil
}

// DownloadURL is scoped to the album the middleware already checked
func (s *CoverService) DownloadURL(ctx context.Context, albumID, coverID uuid.UUID) (*DownloadURLResult, error) {
	row, err := s.repo.Get(ctx, albumID, coverID)
	if err != nil {
		if errors.Is(err, repository.ErrCoverNotFound) {
			return nil, apierr.NotFound("cover not found")
		}
		return nil, apierr.Internal("failed to read cover").WithCause(err)
	}
	if !row.Confirmed {
		return nil, apierr.NotFound("cover not found")
	}
	url, err := s.s3.GetPresignedDownloadURL(ctx, row.StorageKey, DownloadURLTTL)
	if err != nil {
		return nil, apierr.Internal("failed to presign cover download").WithCause(err)
	}
	return &DownloadURLResult{URL: url, ExpiresAt: time.Now().Add(DownloadURLTTL)}, nil
}

// Retires uploads that were reserved but never confirmed
func (s *CoverService) RunPendingCleanup(ctx context.Context) {
	run := func() {
		keys, err := s.repo.QueueStalePending(ctx,
			time.Now().Add(-PendingUploadStaleAfter), PendingCleanupBatchSize)
		if err != nil {
			slog.ErrorContext(ctx, "pending cover cleanup failed", "err", err)
			return
		}
		s.cleanup(ctx, keys)
	}

	run()
	ticker := time.NewTicker(PendingCleanupInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			run()
		}
	}
}

func (s *CoverService) drop(ctx context.Context, albumID, coverID uuid.UUID, storageKey string) {
	keys, err := s.repo.DropPending(ctx, albumID, coverID, storageKey)
	if err != nil {
		slog.WarnContext(ctx, "cover: drop pending failed", "err", err)
		return
	}
	s.cleanup(ctx, keys)
}

func (s *CoverService) cleanup(ctx context.Context, keys []string) {
	if s.cleaner != nil && len(keys) > 0 {
		s.cleaner.CleanupObjectKeys(ctx, keys)
	}
}

func coverErr(err error, msg string) error {
	if e := epochErr(err); e != nil {
		return e
	}
	switch {
	case errors.Is(err, repository.ErrNotAlbumAdmin):
		return apierr.Forbidden("only the owner can choose the cover")
	case errors.Is(err, repository.ErrCallerRevoked), errors.Is(err, repository.ErrAlbumNotFound):
		return apierr.MemberRevoked("your access to this album has been revoked")
	}
	return apierr.Internal(msg).WithCause(err)
}

// Offline members converge on their next listing
func emitToOthers(lookup MemberLookup, notifier Notifier, albumID, callerUserID uuid.UUID, event string, payload map[string]any) {
	if notifier == nil || lookup == nil {
		return
	}
	go func() {
		bg := context.Background()
		members, err := lookup.ActiveMemberUserIDs(bg, albumID)
		if err != nil {
			slog.Warn(event+": lookup failed", "err", err, "album_id", albumID)
			return
		}
		ids := make([]uuid.UUID, 0, len(members))
		for _, m := range members {
			if m != callerUserID {
				ids = append(ids, m)
			}
		}
		if len(ids) == 0 {
			return
		}
		if err := notifier.EmitToUsers(bg, ids, event, payload); err != nil {
			slog.Warn(event+": emit failed", "err", err, "album_id", albumID)
		}
	}()
}
