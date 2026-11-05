package service

import (
	"context"
	"encoding/base64"
	"testing"
	"time"

	"github.com/freytastic/miuchio/internal/model"
	"github.com/freytastic/miuchio/internal/repository"
	"github.com/google/uuid"
)

type memCodes struct{ codes map[string]string }

func (m *memCodes) SetOTP(_ context.Context, key, mac string, _ time.Duration) error {
	m.codes[key] = mac
	return nil
}

func (m *memCodes) CheckOTP(_ context.Context, key, mac string, _ int) (bool, error) {
	ok := m.codes[key] == mac
	if ok {
		delete(m.codes, key)
	}
	return ok, nil
}

func (m *memCodes) CheckRateLimit(context.Context, string, int, time.Duration) (bool, error) {
	return true, nil
}

type memTickets struct {
	tickets map[string]repository.DeletionTicket
}

func (m *memTickets) PutTicket(_ context.Context, hash []byte, t repository.DeletionTicket, _ time.Duration) error {
	m.tickets[string(hash)] = t
	return nil
}

func (m *memTickets) TakeTicket(_ context.Context, hash []byte) (repository.DeletionTicket, bool, error) {
	t, ok := m.tickets[string(hash)]
	delete(m.tickets, string(hash))
	return t, ok, nil
}

type fakeDeleter struct {
	albums   []DeletionAlbum
	requests []repository.DeletionTicket
	receipts map[string]bool
}

func (f *fakeDeleter) Preflight(context.Context, uuid.UUID) ([]DeletionAlbum, error) {
	return f.albums, nil
}

func (f *fakeDeleter) Request(_ context.Context, userID uuid.UUID, shared []uuid.UUID, receipt []byte) error {
	f.requests = append(f.requests, repository.DeletionTicket{UserID: userID, SharedAlbumIDs: shared})
	f.receipts[string(receipt)] = true
	return nil
}

func (f *fakeDeleter) AbandonReceipt(_ context.Context, receipt []byte) (bool, error) {
	return f.receipts[string(receipt)], nil
}

type webDeletionRig struct {
	svc     *WebDeletionService
	codes   *memCodes
	deleter *fakeDeleter
	user    *model.User
}

func newWebDeletionRig(user *model.User) *webDeletionRig {
	rig := &webDeletionRig{
		codes:   &memCodes{codes: map[string]string{}},
		deleter: &fakeDeleter{receipts: map[string]bool{}},
		user:    user,
	}
	users := &MockUserStore{GetByEmailHMACFunc: func(context.Context, []byte) (*model.User, error) {
		if rig.user == nil {
			return nil, repository.ErrUserNotFound
		}
		return rig.user, nil
	}}
	rig.svc = NewWebDeletionService(rig.codes, users, &memTickets{tickets: map[string]repository.DeletionTicket{}},
		rig.deleter, nil, testHMACKey)
	return rig
}

func (r *webDeletionRig) sentCode(t *testing.T) string {
	t.Helper()
	select {
	case m := <-r.svc.outbox:
		return m.code
	default:
		t.Fatal("no code was queued")
		return ""
	}
}

func TestWebDeletion_MissingAccountLooksTheSame(t *testing.T) {
	rig := newWebDeletionRig(nil)
	if err := rig.svc.RequestCode(context.Background(), "nobody@example.com"); err != nil {
		t.Fatalf("RequestCode: %v", err)
	}
	if len(rig.svc.outbox) != 0 {
		t.Fatal("mail was queued for an address with no account")
	}
	if len(rig.codes.codes) != 1 {
		t.Fatal("missing account must still store a code so both paths do the same work")
	}
}

func TestWebDeletion_CodeDoesNotReachALaterAccount(t *testing.T) {
	rig := newWebDeletionRig(&model.User{ID: uuid.New()})
	ctx := context.Background()
	if err := rig.svc.RequestCode(ctx, "a@example.com"); err != nil {
		t.Fatalf("RequestCode: %v", err)
	}
	code := rig.sentCode(t)

	// Same address, new account after the first was deleted
	rig.user = &model.User{ID: uuid.New()}
	if _, _, err := rig.svc.VerifyCode(ctx, "a@example.com", code); err != ErrInvalidOTP {
		t.Fatalf("VerifyCode = %v, want ErrInvalidOTP", err)
	}
}

func TestWebDeletion_TicketConfirmsOnceWithTheReviewedPlan(t *testing.T) {
	userID := uuid.New()
	rig := newWebDeletionRig(&model.User{ID: userID})
	shared := uuid.New()
	rig.deleter.albums = []DeletionAlbum{
		{AlbumID: shared, Outcome: repository.OutcomeDeleteShared, OwnMediaCount: 3},
		{AlbumID: uuid.New(), Outcome: repository.OutcomeLeave, OwnMediaCount: 2},
	}
	ctx := context.Background()
	if err := rig.svc.RequestCode(ctx, "a@example.com"); err != nil {
		t.Fatalf("RequestCode: %v", err)
	}
	ticket, summary, err := rig.svc.VerifyCode(ctx, "a@example.com", rig.sentCode(t))
	if err != nil {
		t.Fatalf("VerifyCode: %v", err)
	}
	if summary != (DeletionSummary{DeletedForEveryone: 1, Left: 1, Photos: 5}) {
		t.Fatalf("summary = %+v", summary)
	}

	if err := rig.svc.Confirm(ctx, ticket); err != nil {
		t.Fatalf("Confirm: %v", err)
	}
	if err := rig.svc.Confirm(ctx, ticket); err != ErrDeletionTicketInvalid {
		t.Fatalf("second Confirm = %v, want ErrDeletionTicketInvalid", err)
	}
	if deleted, err := rig.svc.Settle(ctx, ticket); err != nil || !deleted {
		t.Fatalf("Settle = %v, %v, want the accepted deletion", deleted, err)
	}
	if len(rig.deleter.requests) != 1 {
		t.Fatalf("requests = %d, want 1", len(rig.deleter.requests))
	}
	got := rig.deleter.requests[0]
	if got.UserID != userID || len(got.SharedAlbumIDs) != 1 || got.SharedAlbumIDs[0] != shared {
		t.Fatalf("request = %+v, want the reviewed account and shared album", got)
	}
}

func TestWebDeletion_SettleRejectsTicketsTheServerDidNotIssue(t *testing.T) {
	rig := newWebDeletionRig(&model.User{ID: uuid.New()})
	forged := base64.RawURLEncoding.EncodeToString(make([]byte, deletionTicketLen))
	if _, err := rig.svc.Settle(context.Background(), forged); err != ErrDeletionTicketInvalid {
		t.Fatalf("Settle = %v, want ErrDeletionTicketInvalid", err)
	}
}
