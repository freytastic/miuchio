package service

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"log"
	"math/big"
	"regexp"
	"strings"
	"time"

	"github.com/freytastic/miuchio/internal/handle"
	"github.com/freytastic/miuchio/internal/model"
	"github.com/freytastic/miuchio/internal/repository"
	"github.com/google/uuid"
)

const maxMiuchioIDAttempts = 5

const (
	otpTTL = 5 * time.Minute
	// Wrong guesses allowed per code before it is burned
	maxOTPAttempts = 5
	// Code requests allowed per email per window
	maxOTPRequests   = 3
	otpRequestWindow = 5 * time.Minute
)

// Wrong review codes allowed per window. Only failures count, so reviewers
// signing in again never use it up
const (
	maxReviewFailures   = 10
	reviewFailureWindow = 15 * time.Minute
)

var installIDPattern = regexp.MustCompile(`^[0-9a-f]{32}$`)

// Successful refreshes extend this sliding lifetime
const sessionTTL = 30 * 24 * time.Hour

var (
	ErrInvalidOTP      = errors.New("invalid or expired OTP")
	ErrAccountDeleting = errors.New("account is being deleted")
	ErrTooManyRequests = errors.New("too many requests, please try again later")
	// ErrSessionInvalid marks failures that may invalidate client credentials
	ErrSessionInvalid = errors.New("invalid or expired session")
)

// OTPStore keys are the hex email HMAC and values are code HMACs, never plaintext
type OTPStore interface {
	SetOTP(ctx context.Context, key, codeMAC string, ttl time.Duration) error
	CheckOTP(ctx context.Context, key, codeMAC string, maxAttempts int) (bool, error)
	CheckRateLimit(ctx context.Context, key string, max int, window time.Duration) (bool, error)
	SpendFailureBudget(ctx context.Context, key string, correct bool, max int, window time.Duration) (bool, error)
}

type AuthUserStore interface {
	GetByEmailHMAC(ctx context.Context, hmac []byte) (*model.User, error)
	Create(ctx context.Context, user *model.User) error
}

type SessionStore interface {
	Create(ctx context.Context, session *model.Session) error
	GetByToken(ctx context.Context, token string) (*model.Session, error)
	DeleteByToken(ctx context.Context, token string) error
	ExtendByToken(ctx context.Context, token string, expiresAt time.Time) error
}

type AuthService struct {
	OTPRepo      OTPStore
	UserRepo     AuthUserStore
	SessionRepo  SessionStore
	EmailService EmailService
	emailHMACKey []byte
	otpKey       []byte
	reviewEmail  string
	reviewCode   string
	acceptAnyOTP bool
}

// Lets app reviewers sign in with a fixed code
func (s *AuthService) EnableReviewLogin(email, code string) {
	s.reviewEmail = strings.ToLower(strings.TrimSpace(email))
	s.reviewCode = code
}

// Dev only: any code signs in, so testing never needs the real one
func (s *AuthService) AcceptAnyOTP() {
	s.acceptAnyOTP = true
}

func (s *AuthService) isReviewEmail(email string) bool {
	return s.reviewEmail != "" && strings.ToLower(strings.TrimSpace(email)) == s.reviewEmail
}

func NewAuthService(otpRepo OTPStore, userRepo AuthUserStore, sessionRepo SessionStore, emailService EmailService, emailHMACKey []byte) *AuthService {
	if len(emailHMACKey) < 32 {
		panic("auth service: emailHMACKey must be >= 32 bytes")
	}
	return &AuthService{
		OTPRepo:      otpRepo,
		UserRepo:     userRepo,
		SessionRepo:  sessionRepo,
		EmailService: emailService,
		emailHMACKey: emailHMACKey,
		otpKey:       deriveOTPKey(emailHMACKey),
	}
}

// Separate key so a code MAC can never equal an email HMAC
func deriveOTPKey(emailHMACKey []byte) []byte {
	mac := hmac.New(sha256.New, emailHMACKey)
	mac.Write([]byte("miuchio-otp-key-v1"))
	return mac.Sum(nil)
}

// A plain hash of a 6 digit code falls to a million guesses, so the stored
// value is keyed and bound to the email it was sent to
func (s *AuthService) otpMAC(emailHMAC []byte, otp string) string {
	mac := hmac.New(sha256.New, s.otpKey)
	mac.Write(emailHMAC)
	mac.Write([]byte(otp))
	return hex.EncodeToString(mac.Sum(nil))
}

// HashEmail computes HMAC-SHA256(emailHMACKey, lower(trim(email))), after which
// the plaintext can be discarded
func (s *AuthService) HashEmail(email string) []byte {
	mac := hmac.New(sha256.New, s.emailHMACKey)
	mac.Write([]byte(strings.ToLower(strings.TrimSpace(email))))
	return mac.Sum(nil)
}

func (s *AuthService) RequestOTP(ctx context.Context, email string) error {
	// Logs never carry the email or code: the server is the one place they could
	// be joined to a real identity
	if s.isReviewEmail(email) {
		return nil
	}
	emailHMAC := s.HashEmail(email)
	key := hex.EncodeToString(emailHMAC)
	allowed, err := s.OTPRepo.CheckRateLimit(ctx, key, maxOTPRequests, otpRequestWindow)
	if err != nil {
		log.Printf("RequestOTP: rate limit check failed: %v", err)
		return err
	}
	if !allowed {
		return ErrTooManyRequests
	}

	otp, err := generateOTP(6)
	if err != nil {
		log.Printf("RequestOTP: generate failed: %v", err)
		return err
	}

	if err := s.OTPRepo.SetOTP(ctx, key, s.otpMAC(emailHMAC, otp), otpTTL); err != nil {
		log.Printf("RequestOTP: store failed: %v", err)
		return err
	}

	if err := s.EmailService.SendOTP(email, otp); err != nil {
		log.Printf("RequestOTP: send failed: %v", err)
		return err
	}

	return nil
}

// VerifiedSession identifies the account before credentials are persisted
type VerifiedSession struct {
	UserID    uuid.UUID
	Token     string
	ExpiresAt time.Time
}

// installID is only read for the review email
func (s *AuthService) VerifyOTP(ctx context.Context, email, otp, installID string) (VerifiedSession, error) {
	var emailHMAC []byte
	if s.isReviewEmail(email) {
		var err error
		if emailHMAC, err = s.checkReviewCode(ctx, otp, installID); err != nil {
			return VerifiedSession{}, err
		}
	} else {
		emailHMAC = s.HashEmail(email)
		if err := s.checkOTP(ctx, emailHMAC, otp); err != nil {
			return VerifiedSession{}, err
		}
	}

	user, err := s.UserRepo.GetByEmailHMAC(ctx, emailHMAC)
	if err != nil {
		if errors.Is(err, repository.ErrUserNotFound) {
			user = &model.User{EmailHMAC: emailHMAC}
			if err := s.createWithMiuchioID(ctx, user); err != nil {
				log.Printf("VerifyOTP: user create failed: %v", err)
				return VerifiedSession{}, err
			}
		} else {
			log.Printf("VerifyOTP: user fetch failed: %v", err)
			return VerifiedSession{}, err
		}
	}
	if user.DeletingAt != nil {
		return VerifiedSession{}, ErrAccountDeleting
	}

	token, err := generateToken(32)
	if err != nil {
		return VerifiedSession{}, err
	}

	session := &model.Session{
		UserID:    user.ID,
		TokenHash: repository.HashToken(token),
		ExpiresAt: time.Now().Add(sessionTTL),
	}

	if err := s.SessionRepo.Create(ctx, session); err != nil {
		log.Printf("VerifyOTP: session create failed: %v", err)
		return VerifiedSession{}, err
	}

	return VerifiedSession{
		UserID:    user.ID,
		Token:     token,
		ExpiresAt: session.ExpiresAt,
	}, nil
}

func (s *AuthService) checkOTP(ctx context.Context, emailHMAC []byte, otp string) error {
	if s.acceptAnyOTP {
		return nil
	}
	ok, err := s.OTPRepo.CheckOTP(ctx, hex.EncodeToString(emailHMAC), s.otpMAC(emailHMAC, otp), maxOTPAttempts)
	if err != nil {
		// Intentionally no email/otp in the log line
		log.Printf("VerifyOTP: check failed: %v", err)
		return err
	}
	if !ok {
		return ErrInvalidOTP
	}
	return nil
}

// Returns the per installation account key. The install ID is folded into the
// hashed address, so a review account can never match a real user
func (s *AuthService) checkReviewCode(ctx context.Context, otp, installID string) ([]byte, error) {
	if !installIDPattern.MatchString(installID) {
		return nil, ErrInvalidOTP
	}
	correct := subtle.ConstantTimeCompare([]byte(otp), []byte(s.reviewCode)) == 1
	key := hex.EncodeToString(s.HashEmail(s.reviewEmail)) + ":review"
	allowed, err := s.OTPRepo.SpendFailureBudget(ctx, key, correct, maxReviewFailures, reviewFailureWindow)
	if err != nil {
		log.Printf("VerifyOTP: review failure budget failed: %v", err)
		return nil, err
	}
	if !allowed {
		return nil, ErrTooManyRequests
	}
	if !correct {
		return nil, ErrInvalidOTP
	}
	return s.HashEmail(s.reviewEmail + "#install:" + installID), nil
}

// createWithMiuchioID assigns a fresh random miuchio_id and inserts, retrying on
// the (astronomically rare) UNIQUE collision so registration never fails for it
func (s *AuthService) createWithMiuchioID(ctx context.Context, user *model.User) error {
	var err error
	for range maxMiuchioIDAttempts {
		var id string
		if id, err = handle.Generate(rand.Reader); err != nil {
			return err
		}
		user.MiuchioID = id
		if err = s.UserRepo.Create(ctx, user); err == nil {
			return nil
		}
		if !errors.Is(err, repository.ErrMiuchioIDTaken) {
			return err
		}
	}
	return err
}

// RefreshSession extends in place so a lost response can be retried safely
func (s *AuthService) RefreshSession(ctx context.Context, refreshToken string) (string, string, time.Time, error) {
	session, err := s.SessionRepo.GetByToken(ctx, refreshToken)
	if errors.Is(err, repository.ErrSessionNotFound) {
		return "", "", time.Time{}, ErrSessionInvalid
	}
	if err != nil {
		// Preserve repository failures so the client keeps its credentials
		log.Printf("RefreshSession: session read failed: %v", err)
		return "", "", time.Time{}, err
	}

	if time.Now().After(session.ExpiresAt) {
		return "", "", time.Time{}, ErrSessionInvalid
	}

	newExpiresAt := time.Now().Add(sessionTTL)
	if err := s.SessionRepo.ExtendByToken(ctx, refreshToken, newExpiresAt); err != nil {
		if errors.Is(err, repository.ErrSessionNotFound) {
			return "", "", time.Time{}, ErrSessionInvalid
		}
		log.Printf("RefreshSession: session extend failed: %v", err)
		return "", "", time.Time{}, err
	}

	// The opaque token serves as both access and refresh token
	return refreshToken, refreshToken, newExpiresAt, nil
}

func generateOTP(length int) (string, error) {
	const digits = "0123456789"
	result := make([]byte, length)
	for i := range result {
		num, err := rand.Int(rand.Reader, big.NewInt(int64(len(digits))))
		if err != nil {
			return "", err
		}
		result[i] = digits[num.Int64()]
	}
	return string(result), nil
}

func generateToken(length int) (string, error) {
	b := make([]byte, length)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.URLEncoding.EncodeToString(b), nil
}
