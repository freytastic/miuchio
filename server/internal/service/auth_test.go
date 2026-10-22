package service

import (
	"context"
	"encoding/hex"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/freytastic/miuchio/internal/handle"
	"github.com/freytastic/miuchio/internal/model"
	"github.com/freytastic/miuchio/internal/repository"
	"github.com/google/uuid"
)

type MockOTPStore struct {
	SetOTPFunc             func(ctx context.Context, key, codeMAC string, ttl time.Duration) error
	CheckOTPFunc           func(ctx context.Context, key, codeMAC string, maxAttempts int) (bool, error)
	CheckRateLimitFunc     func(ctx context.Context, key string, max int, window time.Duration) (bool, error)
	SpendFailureBudgetFunc func(ctx context.Context, key string, correct bool, max int, window time.Duration) (bool, error)
}

func (m *MockOTPStore) SetOTP(ctx context.Context, k, c string, t time.Duration) error {
	return m.SetOTPFunc(ctx, k, c, t)
}
func (m *MockOTPStore) CheckOTP(ctx context.Context, k, c string, n int) (bool, error) {
	return m.CheckOTPFunc(ctx, k, c, n)
}
func (m *MockOTPStore) CheckRateLimit(ctx context.Context, k string, n int, w time.Duration) (bool, error) {
	return m.CheckRateLimitFunc(ctx, k, n, w)
}
func (m *MockOTPStore) SpendFailureBudget(ctx context.Context, k string, c bool, n int, w time.Duration) (bool, error) {
	return m.SpendFailureBudgetFunc(ctx, k, c, n, w)
}

// otpMatches accepts only the MAC the service derives for code
func otpMatches(code string) func(context.Context, string, string, int) (bool, error) {
	s := NewAuthService(nil, nil, nil, nil, testHMACKey)
	return func(_ context.Context, key, codeMAC string, _ int) (bool, error) {
		emailHMAC, err := hex.DecodeString(key)
		if err != nil {
			return false, err
		}
		return codeMAC == s.otpMAC(emailHMAC, code), nil
	}
}

type MockUserStore struct {
	GetByEmailHMACFunc func(ctx context.Context, hmac []byte) (*model.User, error)
	CreateFunc         func(ctx context.Context, user *model.User) error
}

func (m *MockUserStore) GetByEmailHMAC(ctx context.Context, h []byte) (*model.User, error) {
	return m.GetByEmailHMACFunc(ctx, h)
}
func (m *MockUserStore) Create(ctx context.Context, u *model.User) error { return m.CreateFunc(ctx, u) }

type MockSessionStore struct {
	CreateFunc        func(ctx context.Context, session *model.Session) error
	GetByTokenFunc    func(ctx context.Context, token string) (*model.Session, error)
	DeleteByTokenFunc func(ctx context.Context, token string) error
	ExtendByTokenFunc func(ctx context.Context, token string, expiresAt time.Time) error
}

func (m *MockSessionStore) ExtendByToken(ctx context.Context, token string, expiresAt time.Time) error {
	if m.ExtendByTokenFunc != nil {
		return m.ExtendByTokenFunc(ctx, token, expiresAt)
	}
	return nil
}

func (m *MockSessionStore) Create(ctx context.Context, s *model.Session) error {
	return m.CreateFunc(ctx, s)
}
func (m *MockSessionStore) GetByToken(ctx context.Context, token string) (*model.Session, error) {
	if m.GetByTokenFunc != nil {
		return m.GetByTokenFunc(ctx, token)
	}
	return nil, errors.New("not implemented")
}
func (m *MockSessionStore) DeleteByToken(ctx context.Context, token string) error {
	if m.DeleteByTokenFunc != nil {
		return m.DeleteByTokenFunc(ctx, token)
	}
	return nil
}

type MockEmailService struct {
	SendOTPFunc func(email, otp string) error
}

func (m *MockEmailService) SendOTP(e, o string) error { return m.SendOTPFunc(e, o) }

// testHMACKey : 32 bytes, deterministic so tests are reproducible
var testHMACKey = []byte("test-email-hmac-key-32-bytes!!!!")

func TestAuthService_VerifyOTP(t *testing.T) {
	email := "test@example.com"
	correctOTP := "123456"

	tests := []struct {
		name          string
		otp           string
		mockOTP       func() *MockOTPStore
		mockUser      func() *MockUserStore
		mockSession   func() *MockSessionStore
		wantErr       error
		expectNewUser bool
	}{
		{
			name: "Success : Existing User",
			otp:  correctOTP,
			mockOTP: func() *MockOTPStore {
				return &MockOTPStore{
					CheckOTPFunc: otpMatches(correctOTP),
				}
			},
			mockUser: func() *MockUserStore {
				return &MockUserStore{
					GetByEmailHMACFunc: func(ctx context.Context, _ []byte) (*model.User, error) {
						return &model.User{ID: uuid.New()}, nil
					},
				}
			},
			mockSession: func() *MockSessionStore {
				return &MockSessionStore{
					CreateFunc: func(ctx context.Context, s *model.Session) error { return nil },
				}
			},
			wantErr:       nil,
			expectNewUser: false,
		},
		{
			name: "Success : New User Created",
			otp:  correctOTP,
			mockOTP: func() *MockOTPStore {
				return &MockOTPStore{
					CheckOTPFunc: otpMatches(correctOTP),
				}
			},
			mockUser: func() *MockUserStore {
				return &MockUserStore{
					GetByEmailHMACFunc: func(ctx context.Context, _ []byte) (*model.User, error) {
						return nil, repository.ErrUserNotFound
					},
					CreateFunc: func(ctx context.Context, u *model.User) error {
						u.ID = uuid.New()
						return nil
					},
				}
			},
			mockSession: func() *MockSessionStore {
				return &MockSessionStore{
					CreateFunc: func(ctx context.Context, s *model.Session) error { return nil },
				}
			},
			wantErr:       nil,
			expectNewUser: true,
		},
		{
			name: "Failure : Wrong OTP",
			otp:  "wrong",
			mockOTP: func() *MockOTPStore {
				return &MockOTPStore{
					CheckOTPFunc: otpMatches(correctOTP),
				}
			},
			mockUser:    func() *MockUserStore { return &MockUserStore{} },
			mockSession: func() *MockSessionStore { return &MockSessionStore{} },
			wantErr:     ErrInvalidOTP,
		},
		{
			name: "Failure : OTP Expired (Not in Redis)",
			otp:  correctOTP,
			mockOTP: func() *MockOTPStore {
				return &MockOTPStore{
					CheckOTPFunc: func(context.Context, string, string, int) (bool, error) { return false, nil },
				}
			},
			mockUser:    func() *MockUserStore { return &MockUserStore{} },
			mockSession: func() *MockSessionStore { return &MockSessionStore{} },
			wantErr:     ErrInvalidOTP,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := NewAuthService(tt.mockOTP(), tt.mockUser(), tt.mockSession(), &MockEmailService{}, testHMACKey)

			got, err := s.VerifyOTP(context.Background(), email, tt.otp, "")

			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Errorf("VerifyOTP() error = %v, wantErr %v", err, tt.wantErr)
				}
				return
			}

			if err != nil {
				t.Fatalf("VerifyOTP() unexpected error: %v", err)
			}

			if got.Token == "" {
				t.Errorf("VerifyOTP() returned empty token on success")
			}
		})
	}
}

func TestAuthService_VerifyOTP_MiuchioIDCollisionRetry(t *testing.T) {
	correctOTP := "123456"
	calls := 0
	var lastUser *model.User

	userStore := &MockUserStore{
		GetByEmailHMACFunc: func(ctx context.Context, _ []byte) (*model.User, error) {
			return nil, repository.ErrUserNotFound
		},
		CreateFunc: func(ctx context.Context, u *model.User) error {
			calls++
			lastUser = u
			if calls == 1 {
				return repository.ErrMiuchioIDTaken
			}
			u.ID = uuid.New()
			return nil
		},
	}
	otpStore := &MockOTPStore{
		CheckOTPFunc: otpMatches(correctOTP),
	}
	sessStore := &MockSessionStore{
		CreateFunc: func(ctx context.Context, s *model.Session) error { return nil },
	}

	s := NewAuthService(otpStore, userStore, sessStore, &MockEmailService{}, testHMACKey)
	got, err := s.VerifyOTP(context.Background(), "new@example.com", correctOTP, "")
	if err != nil {
		t.Fatalf("VerifyOTP unexpected err: %v", err)
	}
	if got.Token == "" {
		t.Fatal("empty token on success")
	}
	if calls != 2 {
		t.Fatalf("Create called %d times, want 2 (collision + retry)", calls)
	}
	if lastUser == nil || len(lastUser.MiuchioID) != handle.Length {
		t.Fatalf("user.MiuchioID not set to a valid handle: %+v", lastUser)
	}
}

// VerifyOTP must identify the account before the client persists credentials
func TestAuthService_VerifyOTP_ReturnsUserIDAndSessionExpiry(t *testing.T) {
	correctOTP := "123456"
	userID := uuid.New()
	var created *model.Session

	otpStore := &MockOTPStore{
		CheckOTPFunc: otpMatches(correctOTP),
	}
	userStore := &MockUserStore{
		GetByEmailHMACFunc: func(ctx context.Context, _ []byte) (*model.User, error) {
			return &model.User{ID: userID}, nil
		},
	}
	sessStore := &MockSessionStore{
		CreateFunc: func(ctx context.Context, s *model.Session) error {
			created = s
			return nil
		},
	}

	s := NewAuthService(otpStore, userStore, sessStore, &MockEmailService{}, testHMACKey)
	got, err := s.VerifyOTP(context.Background(), "test@example.com", correctOTP, "")
	if err != nil {
		t.Fatalf("VerifyOTP unexpected error: %v", err)
	}

	if got.UserID != userID {
		t.Errorf("UserID = %v, want %v", got.UserID, userID)
	}
	if got.Token == "" {
		t.Error("Token is empty")
	}
	// Return the exact persisted expiry
	if !got.ExpiresAt.Equal(created.ExpiresAt) {
		t.Errorf("ExpiresAt = %v, want the created session's %v", got.ExpiresAt, created.ExpiresAt)
	}
}

// A lost refresh response must be retryable with the same token
func TestAuthService_RefreshSession_ExtendsInPlaceAndIsRetrySafe(t *testing.T) {
	const token = "existing-opaque-token"
	userID := uuid.New()
	oldExpiry := time.Now().Add(10 * 24 * time.Hour)
	deleted := false
	var extendedTo time.Time

	sessStore := &MockSessionStore{
		GetByTokenFunc: func(ctx context.Context, tk string) (*model.Session, error) {
			if tk != token {
				return nil, errors.New("not found")
			}
			return &model.Session{UserID: userID, ExpiresAt: oldExpiry}, nil
		},
		DeleteByTokenFunc: func(ctx context.Context, tk string) error {
			deleted = true
			return nil
		},
		ExtendByTokenFunc: func(ctx context.Context, tk string, exp time.Time) error {
			extendedTo = exp
			return nil
		},
	}

	s := NewAuthService(&MockOTPStore{}, &MockUserStore{}, sessStore, &MockEmailService{}, testHMACKey)
	gotToken, gotRefresh, gotExpiry, err := s.RefreshSession(context.Background(), token)
	if err != nil {
		t.Fatalf("RefreshSession unexpected error: %v", err)
	}

	if gotToken != token || gotRefresh != token {
		t.Errorf("token rotated to %q/%q, want the same %q kept valid", gotToken, gotRefresh, token)
	}
	if deleted {
		t.Error("DeleteByToken was called: a retried refresh would find the session gone")
	}
	if !gotExpiry.After(oldExpiry) {
		t.Errorf("expiry %v did not slide past %v", gotExpiry, oldExpiry)
	}
	if !extendedTo.Equal(gotExpiry) {
		t.Errorf("persisted expiry %v does not match returned %v", extendedTo, gotExpiry)
	}
}

// A session deleted during refresh must not be reported as renewed
func TestAuthService_RefreshSession_FailsWhenTheSessionVanished(t *testing.T) {
	const token = "vanishing-token"
	sessStore := &MockSessionStore{
		GetByTokenFunc: func(ctx context.Context, tk string) (*model.Session, error) {
			return &model.Session{
				UserID:    uuid.New(),
				ExpiresAt: time.Now().Add(10 * 24 * time.Hour),
			}, nil
		},
		ExtendByTokenFunc: func(ctx context.Context, tk string, exp time.Time) error {
			return repository.ErrSessionNotFound
		},
	}

	s := NewAuthService(&MockOTPStore{}, &MockUserStore{}, sessStore, &MockEmailService{}, testHMACKey)
	gotToken, _, _, err := s.RefreshSession(context.Background(), token)
	if err == nil {
		t.Fatal("RefreshSession reported success for a session that no longer exists")
	}
	if gotToken != "" {
		t.Errorf("token = %q, want empty on failure", gotToken)
	}
}

// Database failures must not become ErrSessionInvalid and trigger logout
func TestAuthService_RefreshSession_SeparatesDeadSessionFromBrokenDatabase(t *testing.T) {
	dbDown := errors.New("connection refused")

	tests := []struct {
		name        string
		sess        *MockSessionStore
		wantInvalid bool
	}{
		{
			name: "unknown token is an invalid session",
			sess: &MockSessionStore{
				GetByTokenFunc: func(ctx context.Context, tk string) (*model.Session, error) {
					return nil, repository.ErrSessionNotFound
				},
			},
			wantInvalid: true,
		},
		{
			name: "expired session is an invalid session",
			sess: &MockSessionStore{
				GetByTokenFunc: func(ctx context.Context, tk string) (*model.Session, error) {
					return &model.Session{ExpiresAt: time.Now().Add(-time.Hour)}, nil
				},
			},
			wantInvalid: true,
		},
		{
			name: "session that vanished mid refresh is an invalid session",
			sess: &MockSessionStore{
				GetByTokenFunc: func(ctx context.Context, tk string) (*model.Session, error) {
					return &model.Session{ExpiresAt: time.Now().Add(time.Hour)}, nil
				},
				ExtendByTokenFunc: func(ctx context.Context, tk string, e time.Time) error {
					return repository.ErrSessionNotFound
				},
			},
			wantInvalid: true,
		},
		{
			name: "a read failure is NOT an invalid session",
			sess: &MockSessionStore{
				GetByTokenFunc: func(ctx context.Context, tk string) (*model.Session, error) {
					return nil, dbDown
				},
			},
			wantInvalid: false,
		},
		{
			name: "a write failure is NOT an invalid session",
			sess: &MockSessionStore{
				GetByTokenFunc: func(ctx context.Context, tk string) (*model.Session, error) {
					return &model.Session{ExpiresAt: time.Now().Add(time.Hour)}, nil
				},
				ExtendByTokenFunc: func(ctx context.Context, tk string, e time.Time) error {
					return dbDown
				},
			},
			wantInvalid: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := NewAuthService(&MockOTPStore{}, &MockUserStore{}, tt.sess, &MockEmailService{}, testHMACKey)
			_, _, _, err := s.RefreshSession(context.Background(), "tok")
			if err == nil {
				t.Fatal("expected an error")
			}
			if got := errors.Is(err, ErrSessionInvalid); got != tt.wantInvalid {
				t.Errorf("errors.Is(err, ErrSessionInvalid) = %v, want %v (err = %v)",
					got, tt.wantInvalid, err)
			}
		})
	}
}

// Redis must only ever see the email HMAC and a keyed MAC of the code
func TestAuthService_RequestOTP_StoresNoPlaintext(t *testing.T) {
	const email = "Person@Example.com"
	var keys []string
	var stored, sent string
	otpStore := &MockOTPStore{
		CheckRateLimitFunc: func(_ context.Context, k string, _ int, _ time.Duration) (bool, error) {
			keys = append(keys, k)
			return true, nil
		},
		SetOTPFunc: func(_ context.Context, k, c string, _ time.Duration) error {
			keys = append(keys, k)
			stored = c
			return nil
		},
	}
	mail := &MockEmailService{SendOTPFunc: func(_, o string) error { sent = o; return nil }}

	s := NewAuthService(otpStore, &MockUserStore{}, &MockSessionStore{}, mail, testHMACKey)
	if err := s.RequestOTP(context.Background(), email); err != nil {
		t.Fatalf("RequestOTP: %v", err)
	}

	want := hex.EncodeToString(s.HashEmail(email))
	for _, k := range keys {
		if k != want {
			t.Errorf("store key = %q, want the email HMAC %q", k, want)
		}
		if strings.Contains(strings.ToLower(k), "example") {
			t.Errorf("store key %q contains the email", k)
		}
	}
	if stored == "" || strings.Contains(stored, sent) {
		t.Errorf("stored value %q exposes the code %q", stored, sent)
	}
	// Bound to the email : the same code for another address must not match
	if stored == s.otpMAC(s.HashEmail("other@example.com"), sent) {
		t.Error("code MAC is not bound to the email")
	}
}

func TestAuthService_VerifyOTP_PassesAttemptLimit(t *testing.T) {
	var got int
	otpStore := &MockOTPStore{
		CheckOTPFunc: func(_ context.Context, _, _ string, n int) (bool, error) {
			got = n
			return false, nil
		},
	}
	s := NewAuthService(otpStore, &MockUserStore{}, &MockSessionStore{}, &MockEmailService{}, testHMACKey)
	if _, err := s.VerifyOTP(context.Background(), "a@b.c", "000000", ""); !errors.Is(err, ErrInvalidOTP) {
		t.Fatalf("err = %v, want ErrInvalidOTP", err)
	}
	if got != maxOTPAttempts {
		t.Errorf("maxAttempts = %d, want %d", got, maxOTPAttempts)
	}
}

// A store failure is not a wrong code : the user must not be told to retype
func TestAuthService_VerifyOTP_StoreFailureIsNotInvalidOTP(t *testing.T) {
	down := errors.New("redis down")
	otpStore := &MockOTPStore{
		CheckOTPFunc: func(context.Context, string, string, int) (bool, error) { return false, down },
	}
	s := NewAuthService(otpStore, &MockUserStore{}, &MockSessionStore{}, &MockEmailService{}, testHMACKey)
	_, err := s.VerifyOTP(context.Background(), "a@b.c", "000000", "")
	if !errors.Is(err, down) {
		t.Fatalf("err = %v, want the store error", err)
	}
}

const (
	reviewEmail = "review-k3j9x2m8q4w7p1z5@miuchio.com"
	reviewCode  = "424242"
	installA    = "0123456789abcdef0123456789abcdef"
	installB    = "fedcba9876543210fedcba9876543210"
)

// reviewHarness keeps failure counts and accounts like Redis and Postgres would
type reviewHarness struct {
	failures int
	accounts map[string]uuid.UUID
	svc      *AuthService
}

func newReviewHarness() *reviewHarness {
	h := &reviewHarness{accounts: map[string]uuid.UUID{}}
	otpStore := &MockOTPStore{
		SpendFailureBudgetFunc: func(_ context.Context, _ string, correct bool, max int, _ time.Duration) (bool, error) {
			if h.failures >= max {
				return false, nil
			}
			if !correct {
				h.failures++
			}
			return true, nil
		},
		CheckRateLimitFunc: func(context.Context, string, int, time.Duration) (bool, error) {
			return false, errors.New("review login must not use the request limit")
		},
		CheckOTPFunc: func(context.Context, string, string, int) (bool, error) {
			return false, errors.New("review login must not read stored codes")
		},
		SetOTPFunc: func(context.Context, string, string, time.Duration) error {
			return errors.New("review login must not store codes")
		},
	}
	users := &MockUserStore{
		GetByEmailHMACFunc: func(_ context.Context, hm []byte) (*model.User, error) {
			if id, ok := h.accounts[string(hm)]; ok {
				return &model.User{ID: id, EmailHMAC: hm}, nil
			}
			return nil, repository.ErrUserNotFound
		},
		CreateFunc: func(_ context.Context, u *model.User) error {
			u.ID = uuid.New()
			h.accounts[string(u.EmailHMAC)] = u.ID
			return nil
		},
	}
	sessions := &MockSessionStore{CreateFunc: func(context.Context, *model.Session) error { return nil }}
	mail := &MockEmailService{SendOTPFunc: func(string, string) error {
		return errors.New("review login must not send email")
	}}
	h.svc = NewAuthService(otpStore, users, sessions, mail, testHMACKey)
	h.svc.EnableReviewLogin(reviewEmail, reviewCode)
	return h
}

func (h *reviewHarness) signIn(t *testing.T, code, install string) (uuid.UUID, error) {
	t.Helper()
	got, err := h.svc.VerifyOTP(context.Background(), reviewEmail, code, install)
	return got.UserID, err
}

func TestAuthService_ReviewLogin_RequestSendsNothing(t *testing.T) {
	h := newReviewHarness()
	if err := h.svc.RequestOTP(context.Background(), " Review-K3J9X2M8Q4W7P1Z5@Miuchio.com "); err != nil {
		t.Fatalf("RequestOTP: %v", err)
	}
}

// Each installation keeps one account of its own, never a real user's
func TestAuthService_ReviewLogin_AccountPerInstallation(t *testing.T) {
	h := newReviewHarness()
	first, err := h.signIn(t, reviewCode, installA)
	if err != nil {
		t.Fatal(err)
	}
	again, _ := h.signIn(t, reviewCode, installA)
	other, _ := h.signIn(t, reviewCode, installB)
	if again != first {
		t.Error("signing in again on the same installation changed the account")
	}
	if other == first {
		t.Error("two installations share an account")
	}
	if _, ok := h.accounts[string(h.svc.HashEmail(reviewEmail))]; ok {
		t.Error("a review account sits on the plain review address")
	}
}

// Reviewers signing in repeatedly must never lock each other out
func TestAuthService_ReviewLogin_SuccessesDoNotCount(t *testing.T) {
	h := newReviewHarness()
	for i := range maxReviewFailures * 3 {
		if _, err := h.signIn(t, reviewCode, installA); err != nil {
			t.Fatalf("sign in %d: %v", i, err)
		}
	}
	if h.failures != 0 {
		t.Errorf("failures = %d after only correct codes", h.failures)
	}
}

func TestAuthService_ReviewLogin_WrongCodesLockEvenTheRightOne(t *testing.T) {
	h := newReviewHarness()
	for range maxReviewFailures {
		if _, err := h.signIn(t, "000000", installA); !errors.Is(err, ErrInvalidOTP) {
			t.Fatalf("err = %v, want ErrInvalidOTP", err)
		}
	}
	if _, err := h.signIn(t, reviewCode, installB); !errors.Is(err, ErrTooManyRequests) {
		t.Fatalf("err = %v, want ErrTooManyRequests once the limit is reached", err)
	}
	if len(h.accounts) != 0 {
		t.Error("a blocked sign in created an account")
	}
}

func TestAuthService_ReviewLogin_RejectsBadInstallID(t *testing.T) {
	for _, id := range []string{"", "not-hex", strings.ToUpper(installA)} {
		h := newReviewHarness()
		if _, err := h.signIn(t, reviewCode, id); !errors.Is(err, ErrInvalidOTP) {
			t.Errorf("install id %q: err = %v, want ErrInvalidOTP", id, err)
		}
		if len(h.accounts) != 0 {
			t.Errorf("install id %q created an account", id)
		}
	}
}

// Without EnableReviewLogin the review address is an ordinary email
func TestAuthService_ReviewLogin_OffByDefault(t *testing.T) {
	otpStore := &MockOTPStore{CheckOTPFunc: otpMatches("111111")}
	s := NewAuthService(otpStore, &MockUserStore{}, &MockSessionStore{}, &MockEmailService{}, testHMACKey)
	if _, err := s.VerifyOTP(context.Background(), reviewEmail, reviewCode, installA); !errors.Is(err, ErrInvalidOTP) {
		t.Fatalf("err = %v, want ErrInvalidOTP", err)
	}
}
