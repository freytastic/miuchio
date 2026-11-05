package handler

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/freytastic/miuchio/internal/apierr"
	"github.com/freytastic/miuchio/internal/service"
)

type webDeleter interface {
	RequestCode(ctx context.Context, email string) error
	VerifyCode(ctx context.Context, email, code string) (string, service.DeletionSummary, error)
	Confirm(ctx context.Context, ticket string) error
	Settle(ctx context.Context, ticket string) (bool, error)
}

// WebDeletionHandler serves the account deletion page on the website. Email,
// code and ticket only ever travel in request bodies, never in URLs
type WebDeletionHandler struct {
	deleter webDeleter
}

func NewWebDeletionHandler(d webDeleter) *WebDeletionHandler {
	return &WebDeletionHandler{deleter: d}
}

func readWebDeletionBody(w http.ResponseWriter, r *http.Request, v any) bool {
	w.Header().Set("Cache-Control", "no-store")
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(v); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body"))
		return false
	}
	return true
}

func writeWebDeletionError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, service.ErrInvalidOTP):
		apierr.Write(w, r, apierr.Auth("invalid or expired code"))
	case errors.Is(err, service.ErrTooManyRequests):
		apierr.Write(w, r, apierr.RateLimited(err.Error()))
	case errors.Is(err, service.ErrDeletionTicketInvalid):
		apierr.Write(w, r, apierr.Auth("this confirmation expired, start again"))
	default:
		var ae *apierr.APIError
		if errors.As(err, &ae) {
			apierr.Write(w, r, ae)
			return
		}
		apierr.Write(w, r, apierr.Internal("account deletion failed").WithCause(err))
	}
}

// RequestCode handles POST /web-deletion/code. The answer never says whether
// the address has an account
func (h *WebDeletionHandler) RequestCode(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email string `json:"email"`
	}
	if !readWebDeletionBody(w, r, &req) {
		return
	}
	email := strings.ToLower(strings.TrimSpace(req.Email))
	if email == "" {
		apierr.Write(w, r, apierr.Validation("email is required"))
		return
	}
	if err := h.deleter.RequestCode(r.Context(), email); err != nil {
		writeWebDeletionError(w, r, err)
		return
	}
	w.WriteHeader(http.StatusAccepted)
}

// VerifyCode handles POST /web-deletion/review
func (h *WebDeletionHandler) VerifyCode(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email string `json:"email"`
		Code  string `json:"code"`
	}
	if !readWebDeletionBody(w, r, &req) {
		return
	}
	email := strings.ToLower(strings.TrimSpace(req.Email))
	code := strings.TrimSpace(req.Code)
	if email == "" || code == "" {
		apierr.Write(w, r, apierr.Validation("email and code are required"))
		return
	}
	ticket, summary, err := h.deleter.VerifyCode(r.Context(), email, code)
	if err != nil {
		writeWebDeletionError(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"ticket": ticket, "summary": summary})
}

// Confirm handles POST /web-deletion/confirm
func (h *WebDeletionHandler) Confirm(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Ticket string `json:"ticket"`
	}
	if !readWebDeletionBody(w, r, &req) {
		return
	}
	if err := h.deleter.Confirm(r.Context(), req.Ticket); err != nil {
		writeWebDeletionError(w, r, err)
		return
	}
	w.WriteHeader(http.StatusAccepted)
}

// Settle handles POST /web-deletion/settle. After it answers, the outcome it
// reports can no longer change
func (h *WebDeletionHandler) Settle(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Ticket string `json:"ticket"`
	}
	if !readWebDeletionBody(w, r, &req) {
		return
	}
	deleted, err := h.deleter.Settle(r.Context(), req.Ticket)
	if err != nil {
		writeWebDeletionError(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]bool{"deleted": deleted})
}
