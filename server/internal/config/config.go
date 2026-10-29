package config

import (
	"crypto/sha256"
	"encoding/base64"
	"log"
	"os"
	"regexp"
	"strings"
)

type Config struct {
	DatabaseURL  string
	RedisURL     string
	Port         string
	ResendAPIKey string
	EmailFrom    string
	DevMode      bool // enables /test/* endpoints and any sign-in code: never true in production

	// HMAC key for users.email_hmac. Rotating it orphans every account, so treat
	// it as a primary secret. Required outside dev, dev derives a deterministic
	// placeholder when unset
	EmailHMACKey []byte

	// Master key for userlink, which derives the user_handle HMAC subkey and
	// the user_id_enc AEAD subkey. Rotating it bricks every membership row
	UserLinkKey []byte

	// App store review login, off unless both are set. Both are secrets
	// bcs together they sign in without email
	ReviewEmail string
	ReviewCode  string

	S3Endpoint       string
	S3PublicEndpoint string // optional: used for presigning if S3Endpoint is internal (e.g. http://minio:9000)
	S3AccessKey      string
	S3SecretKey      string
	S3Bucket         string
	S3Region         string
	UsePathStyle     bool
}

func Load() *Config {
	devMode := getEnv("APP_ENV", "") == "dev"
	reviewEmail, reviewCode := loadReviewLogin()
	return &Config{
		DatabaseURL:      getEnv("DATABASE_URL", "postgres://postgres:password@localhost:5432/miuchio?sslmode=disable"),
		RedisURL:         getEnv("REDIS_URL", "localhost:6379"),
		Port:             getEnv("PORT", "8080"),
		ResendAPIKey:     requireOutsideDev("RESEND_API_KEY", devMode),
		EmailFrom:        loadEmailFrom(devMode),
		DevMode:          devMode,
		EmailHMACKey:     loadEmailHMACKey(devMode),
		UserLinkKey:      loadKeyOrDevPlaceholder("MIUCHIO_USER_LINK_KEY", "miuchio-dev-userlink-placeholder-do-not-deploy", devMode),
		ReviewEmail:      reviewEmail,
		ReviewCode:       reviewCode,
		S3Endpoint:       getEnv("S3_ENDPOINT", "http://localhost:9000"),
		S3PublicEndpoint: getEnv("S3_PUBLIC_ENDPOINT", ""),
		S3AccessKey:      getEnv("S3_ACCESS_KEY", "minioadmin"),
		S3SecretKey:      getEnv("S3_SECRET_KEY", "minioadmin"),
		S3Bucket:         getEnv("S3_BUCKET", "miuchio"),
		S3Region:         getEnv("S3_REGION", "auto"),
		UsePathStyle:     getEnv("USE_PATH_STYLE", "true") == "true",
	}
}

func loadEmailHMACKey(devMode bool) []byte {
	return loadKeyOrDevPlaceholder("MIUCHIO_EMAIL_HMAC_KEY", "miuchio-dev-email-hmac-placeholder-do-not-deploy", devMode)
}

// loadKeyOrDevPlaceholder reads a base64 secret of 32B or more. In dev mode a
// missing value falls back to SHA256(devSeed), never deploy with APP_ENV=dev
func loadKeyOrDevPlaceholder(envKey, devSeed string, devMode bool) []byte {
	raw := getEnv(envKey, "")
	if raw != "" {
		key, err := base64.StdEncoding.DecodeString(raw)
		if err != nil {
			log.Fatalf("%s: not valid base64: %v", envKey, err)
		}
		if len(key) < 32 {
			log.Fatalf("%s: must decode to >= 32 bytes, got %d", envKey, len(key))
		}
		return key
	}
	if !devMode {
		log.Fatalf("%s is required in non dev mode", envKey)
	}
	d := sha256.Sum256([]byte(devSeed))
	return d[:]
}

// Resend only delivers its onboarding sender to the account owner, so it is a
// dev fallback and production must name a sender on a verified domain
func loadEmailFrom(devMode bool) string {
	from := requireOutsideDev("EMAIL_FROM", devMode)
	if from == "" {
		return "Miuchio <onboarding@resend.dev>"
	}
	return from
}

// requireOutsideDev stops startup when key is unset outside dev mode, so a
// production server never falls back to printing sign-in codes to its log
func requireOutsideDev(key string, devMode bool) string {
	value := getEnv(key, "")
	if value == "" && !devMode {
		log.Fatalf("%s is required in non dev mode", key)
	}
	return value
}

func loadReviewLogin() (string, string) {
	email := strings.ToLower(strings.TrimSpace(getEnv("REVIEW_EMAIL", "")))
	code := getEnv("REVIEW_CODE", "")
	if email == "" && code == "" {
		return "", ""
	}
	if !reviewEmailPattern.MatchString(email) || !reviewCodePattern.MatchString(code) {
		log.Fatalf("REVIEW_EMAIL must look like review-<16+ random letters or digits>@miuchio.com and REVIEW_CODE must be 6 digits, both set together")
	}
	return email, code
}

var (
	reviewEmailPattern = regexp.MustCompile(`^review-[a-z0-9]{16,}@miuchio\.com$`)
	reviewCodePattern  = regexp.MustCompile(`^[0-9]{6}$`)
)

func getEnv(key, fallback string) string {
	if value, ok := os.LookupEnv(key); ok {
		return value
	}
	return fallback
}
