package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestRateLimiterDisabledLetsEveryRequestThrough(t *testing.T) {
	// No Redis client: a disabled limiter must not touch it
	limiter := NewRateLimiter(nil)
	limiter.Disable()
	handler := limiter.Middleware(func(*http.Request) string { return "pair" }, 1, time.Minute)(
		http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) }),
	)

	for i := range 3 {
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
		if rec.Code != http.StatusNoContent {
			t.Fatalf("request %d: status = %d, want %d", i+1, rec.Code, http.StatusNoContent)
		}
	}
}
