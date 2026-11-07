package service

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/freytastic/miuchio/internal/apierr"
	"github.com/freytastic/miuchio/internal/repository"
	"github.com/google/uuid"
)

const (
	// Fits a sealed 500KB thumbnail carried as base64 inside the sealed JSON
	MaxReportSealed = 720 << 10
	// crypto_box_seal adds 48 bytes, so anything shorter carries nothing
	minReportSealed = 64

	ReportResolvedRetention = 90 * 24 * time.Hour
	ReportOpenRetention     = 180 * 24 * time.Hour
	reportPurgeInterval     = 6 * time.Hour
)

type ReportStore interface {
	Uploader(ctx context.Context, albumID, mediaID uuid.UUID) ([]byte, uuid.UUID, error)
	Create(ctx context.Context, in repository.ReportInput) (uuid.UUID, error)
	Purge(ctx context.Context, resolvedBefore, openBefore time.Time) (int64, error)
}

// Alerts carry only the report id, never its reason, note or photo
type ReportAlerter interface {
	SendReportAlert(ctx context.Context, to string, reportID uuid.UUID) error
}

type ReportService struct {
	repo    ReportStore
	alerts  ReportAlerter
	alertTo string
}

func NewReportService(repo ReportStore, alerts ReportAlerter, alertTo string) *ReportService {
	return &ReportService{repo: repo, alerts: alerts, alertTo: alertTo}
}

type ReportInput struct {
	Kind        string
	MediaID     *uuid.UUID
	MemberToken []byte
	Sealed      []byte
}

// Submit stores an allegation for review. Nothing happens to the subject until
// a person decides
func (s *ReportService) Submit(ctx context.Context, albumID uuid.UUID, reporterToken []byte, in ReportInput) (uuid.UUID, error) {
	if len(in.Sealed) < minReportSealed || len(in.Sealed) > MaxReportSealed {
		return uuid.Nil, apierr.Validation("sealed is out of range for a report")
	}
	subject := in.MemberToken
	var upload *uuid.UUID
	switch in.Kind {
	case "photo":
		if in.MediaID == nil {
			return uuid.Nil, apierr.Validation("media_id is required for a photo report")
		}
		token, u, err := s.repo.Uploader(ctx, albumID, *in.MediaID)
		if errors.Is(err, repository.ErrMediaNotFound) {
			return uuid.Nil, apierr.NotFound("media not found")
		}
		if err != nil {
			return uuid.Nil, apierr.Internal("failed to resolve uploader").WithCause(err)
		}
		subject, upload = token, &u
	case "person":
		if len(subject) != 32 {
			return uuid.Nil, apierr.Validation("member_token must be 32 bytes")
		}
		in.MediaID = nil
	default:
		return uuid.Nil, apierr.Validation("kind must be photo or person")
	}
	if string(subject) == string(reporterToken) {
		return uuid.Nil, apierr.Validation("you can't report yourself")
	}

	id, err := s.repo.Create(ctx, repository.ReportInput{
		AlbumID:       albumID,
		MediaID:       in.MediaID,
		MediaUpload:   upload,
		Kind:          in.Kind,
		SubjectToken:  subject,
		ReporterToken: reporterToken,
		Sealed:        in.Sealed,
	})
	if errors.Is(err, repository.ErrMemberNotFound) {
		return uuid.Nil, apierr.NotFound("member not found")
	}
	if err != nil {
		return uuid.Nil, apierr.Internal("failed to store report").WithCause(err)
	}
	s.alert(id)
	return id, nil
}

func (s *ReportService) alert(id uuid.UUID) {
	if s.alerts == nil || s.alertTo == "" {
		slog.Warn("report received with no moderation email set", "report_id", id)
		return
	}
	go func() {
		if err := s.alerts.SendReportAlert(context.Background(), s.alertTo, id); err != nil {
			slog.Error("report alert failed", "report_id", id, "err", err)
		}
	}()
}

func (s *ReportService) RunRetention(ctx context.Context) {
	run := func() {
		now := time.Now()
		n, err := s.repo.Purge(ctx, now.Add(-ReportResolvedRetention), now.Add(-ReportOpenRetention))
		if err != nil {
			slog.ErrorContext(ctx, "report purge failed", "err", err)
			return
		}
		if n > 0 {
			slog.InfoContext(ctx, "reports purged", "count", n)
		}
	}
	run()
	ticker := time.NewTicker(reportPurgeInterval)
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
