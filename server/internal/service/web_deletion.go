package service

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"log"
	"time"

	"github.com/freytastic/miuchio/internal/model"
	"github.com/freytastic/miuchio/internal/repository"
	"github.com/google/uuid"
)

const (
	deletionTicketTTL = 10 * time.Minute
	// A random nonce then its MAC, so the server can tell its own tickets apart
	// after Redis has forgotten them
	deletionTicketNonceLen = 16
	deletionTicketLen      = 32
	// Mail waiting beyond this is dropped, the person can ask for a new code
	deletionMailQueue = 64
)

var ErrDeletionTicketInvalid = errors.New("deletion ticket is invalid or already used")

type DeletionCodeStore interface {
	SetOTP(ctx context.Context, key, codeMAC string, ttl time.Duration) error
	CheckOTP(ctx context.Context, key, codeMAC string, maxAttempts int) (bool, error)
	CheckRateLimit(ctx context.Context, key string, max int, window time.Duration) (bool, error)
}

type DeletionTicketStore interface {
	PutTicket(ctx context.Context, hash []byte, t repository.DeletionTicket, ttl time.Duration) error
	TakeTicket(ctx context.Context, hash []byte) (repository.DeletionTicket, bool, error)
}

type DeletionUserStore interface {
	GetByEmailHMAC(ctx context.Context, hmac []byte) (*model.User, error)
}

type DeletionCodeMailer interface {
	SendDeletionCode(ctx context.Context, email, code string) error
}

type webAccountDeleter interface {
	Preflight(ctx context.Context, userID uuid.UUID) ([]DeletionAlbum, error)
	Request(ctx context.Context, userID uuid.UUID, confirmedShared []uuid.UUID, receipt []byte) error
	AbandonReceipt(ctx context.Context, receipt []byte) (bool, error)
}

// DeletionSummary is all the browser learns about an account: counts, never
// album ids, names or the Miuchio ID
type DeletionSummary struct {
	DeletedForEveryone int `json:"albums_deleted_for_everyone"`
	Deleted            int `json:"albums_deleted"`
	Left               int `json:"albums_left"`
	Photos             int `json:"photos_deleted"`
}

type deletionMail struct {
	email   string
	code    string
	expires time.Time
}

// WebDeletionService deletes an account for someone who no longer has the app.
// A code mailed to the account proves ownership and buys one short single use
// ticket that can only confirm this deletion, never a session
type WebDeletionService struct {
	codes        DeletionCodeStore
	users        DeletionUserStore
	tickets      DeletionTicketStore
	deletions    webAccountDeleter
	mailer       DeletionCodeMailer
	emailHMACKey []byte
	codeKey      []byte
	ticketKey    []byte
	outbox       chan deletionMail
}

func NewWebDeletionService(codes DeletionCodeStore, users DeletionUserStore, tickets DeletionTicketStore,
	deletions webAccountDeleter, mailer DeletionCodeMailer, emailHMACKey []byte) *WebDeletionService {
	if len(emailHMACKey) < 32 {
		panic("web deletion service: emailHMACKey must be >= 32 bytes")
	}
	return &WebDeletionService{
		codes:        codes,
		users:        users,
		tickets:      tickets,
		deletions:    deletions,
		mailer:       mailer,
		emailHMACKey: emailHMACKey,
		// Distinct from the sign-in key, so neither flow's codes verify in the other
		codeKey:   deriveKey(emailHMACKey, "miuchio-deletion-code-key-v1"),
		ticketKey: deriveKey(emailHMACKey, "miuchio-deletion-ticket-key-v1"),
		outbox:    make(chan deletionMail, deletionMailQueue),
	}
}

// Binding the account id means a code sent to one account never verifies for
// a later account created on the same address
func (s *WebDeletionService) codeMAC(userID uuid.UUID, emailHMAC []byte, code string) string {
	mac := hmac.New(sha256.New, s.codeKey)
	mac.Write(userID[:])
	mac.Write(emailHMAC)
	mac.Write([]byte(code))
	return hex.EncodeToString(mac.Sum(nil))
}

// deletableAccount returns uuid.Nil for an address with no account the page
// may delete. Callers then do the same work as for a real one
func (s *WebDeletionService) deletableAccount(ctx context.Context, emailHMAC []byte) (uuid.UUID, error) {
	user, err := s.users.GetByEmailHMAC(ctx, emailHMAC)
	if errors.Is(err, repository.ErrUserNotFound) {
		return uuid.Nil, nil
	}
	if err != nil {
		return uuid.Nil, err
	}
	if user.DeletingAt != nil {
		return uuid.Nil, nil
	}
	return user.ID, nil
}

// RequestCode answers the same way whether or not the address has an account
// Missing accounts still get a stored code nobody receives, and mail leaves
// through a queue so its latency never reaches the response
func (s *WebDeletionService) RequestCode(ctx context.Context, email string) error {
	emailHMAC := hashEmail(s.emailHMACKey, email)
	key := hex.EncodeToString(emailHMAC)
	allowed, err := s.codes.CheckRateLimit(ctx, key, maxOTPRequests, otpRequestWindow)
	if err != nil {
		return err
	}
	if !allowed {
		return ErrTooManyRequests
	}
	userID, err := s.deletableAccount(ctx, emailHMAC)
	if err != nil {
		return err
	}
	code, err := generateOTP(6)
	if err != nil {
		return err
	}
	if err := s.codes.SetOTP(ctx, key, s.codeMAC(userID, emailHMAC, code), otpTTL); err != nil {
		return err
	}
	if userID == uuid.Nil {
		return nil
	}
	select {
	case s.outbox <- deletionMail{email: email, code: code, expires: time.Now().Add(otpTTL)}:
	default:
		log.Printf("web deletion: mail queue full, code dropped")
	}
	return nil
}

// VerifyCode consumes the code and returns a ticket with what deleting will do
// The ticket keeps the shared albums shown here, which the deletion job checks
// again when it accepts
func (s *WebDeletionService) VerifyCode(ctx context.Context, email, code string) (string, DeletionSummary, error) {
	emailHMAC := hashEmail(s.emailHMACKey, email)
	userID, err := s.deletableAccount(ctx, emailHMAC)
	if err != nil {
		return "", DeletionSummary{}, err
	}
	ok, err := s.codes.CheckOTP(ctx, hex.EncodeToString(emailHMAC), s.codeMAC(userID, emailHMAC, code), maxOTPAttempts)
	if err != nil {
		return "", DeletionSummary{}, err
	}
	if !ok || userID == uuid.Nil {
		return "", DeletionSummary{}, ErrInvalidOTP
	}

	albums, err := s.deletions.Preflight(ctx, userID)
	if err != nil {
		return "", DeletionSummary{}, err
	}
	var summary DeletionSummary
	ticket := repository.DeletionTicket{UserID: userID, SharedAlbumIDs: []uuid.UUID{}}
	for _, a := range albums {
		summary.Photos += a.OwnMediaCount
		switch a.Outcome {
		case repository.OutcomeDeleteShared:
			summary.DeletedForEveryone++
			ticket.SharedAlbumIDs = append(ticket.SharedAlbumIDs, a.AlbumID)
		case repository.OutcomeDeleteAlbum:
			summary.Deleted++
		case repository.OutcomeLeave:
			summary.Left++
		}
	}

	raw := make([]byte, deletionTicketNonceLen, deletionTicketLen)
	if _, err := rand.Read(raw); err != nil {
		return "", DeletionSummary{}, err
	}
	raw = append(raw, s.ticketMAC(raw)...)
	if err := s.tickets.PutTicket(ctx, ticketHash(raw), ticket, deletionTicketTTL); err != nil {
		return "", DeletionSummary{}, err
	}
	return base64.RawURLEncoding.EncodeToString(raw), summary, nil
}

func (s *WebDeletionService) ticketMAC(nonce []byte) []byte {
	mac := hmac.New(sha256.New, s.ticketKey)
	mac.Write(nonce)
	return mac.Sum(nil)[:deletionTicketLen-deletionTicketNonceLen]
}

func (s *WebDeletionService) issuedTicket(ticket string) ([]byte, bool) {
	raw, err := base64.RawURLEncoding.DecodeString(ticket)
	if err != nil || len(raw) != deletionTicketLen {
		return nil, false
	}
	nonce := raw[:deletionTicketNonceLen]
	return raw, hmac.Equal(raw[deletionTicketNonceLen:], s.ticketMAC(nonce))
}

// Confirm spends the ticket before acting, so it authorizes one acceptance at most
func (s *WebDeletionService) Confirm(ctx context.Context, ticket string) error {
	raw, ok := s.issuedTicket(ticket)
	if !ok {
		return ErrDeletionTicketInvalid
	}
	t, ok, err := s.tickets.TakeTicket(ctx, ticketHash(raw))
	if err != nil {
		return err
	}
	if !ok {
		return ErrDeletionTicketInvalid
	}
	return s.deletions.Request(ctx, t.UserID, t.SharedAlbumIDs, webReceipt(raw))
}

// Settle answers a confirm whose response was lost. Abandoning the ticket's
// receipt and accepting it meet on one row, so the answer stays true even if
// the lost confirm arrives later. Only issued tickets get here, so strangers
// cannot make it write rows
func (s *WebDeletionService) Settle(ctx context.Context, ticket string) (bool, error) {
	raw, ok := s.issuedTicket(ticket)
	if !ok {
		return false, ErrDeletionTicketInvalid
	}
	return s.deletions.AbandonReceipt(ctx, webReceipt(raw))
}

func ticketHash(raw []byte) []byte {
	h := sha256.Sum256(raw)
	return h[:]
}

// The browser already holds the ticket, so the receipt needs no second secret
// Labelled so it never equals the ticket's own hash
func webReceipt(raw []byte) []byte {
	h := sha256.New()
	h.Write([]byte("miuchio-web-deletion-receipt-v1"))
	h.Write(raw)
	return h.Sum(nil)
}

func (s *WebDeletionService) RunMailer(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case m := <-s.outbox:
			// A code that expired while queued would only mislead
			if time.Now().After(m.expires) {
				continue
			}
			if err := s.mailer.SendDeletionCode(ctx, m.email, m.code); err != nil {
				log.Printf("web deletion: send failed: %v", err)
			}
		}
	}
}
