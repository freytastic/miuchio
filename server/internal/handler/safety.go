package handler

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"time"

	"github.com/freytastic/miuchio/internal/apierr"
	"github.com/freytastic/miuchio/internal/middleware"
	"github.com/freytastic/miuchio/internal/repository"
	"github.com/freytastic/miuchio/internal/service"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

const (
	// The sealed report as base64 plus a few small fields
	reportBodyLimit = 1 << 20
	blockBodyLimit  = 4 << 10

	MaxReports    = 10
	ReportsWindow = time.Hour
	MaxBlocks     = 30
	BlocksWindow  = time.Hour
)

func KeyReports(r *http.Request) string { return perAccountKey(r, "reports:") }

func KeyBlocks(r *http.Request) string { return perAccountKey(r, "blocks:") }

func perAccountKey(r *http.Request, prefix string) string {
	uid, ok := middleware.GetUserID(r.Context())
	if !ok {
		return ""
	}
	return "ratelimit:" + prefix + uid.String()
}

type reportSubmitter interface {
	Submit(ctx context.Context, albumID uuid.UUID, reporterToken []byte, in service.ReportInput) (uuid.UUID, error)
}

type blocker interface {
	Block(ctx context.Context, albumID, callerID uuid.UUID, targetToken []byte) (repository.Block, error)
	List(ctx context.Context, callerID uuid.UUID) ([]repository.Block, error)
	Unblock(ctx context.Context, callerID, id uuid.UUID) error
}

type SafetyHandler struct {
	reports reportSubmitter
	blocks  blocker
}

func NewSafetyHandler(reports reportSubmitter, blocks blocker) *SafetyHandler {
	return &SafetyHandler{reports: reports, blocks: blocks}
}

// Report handles POST /albums/{id}/reports
func (h *SafetyHandler) Report(w http.ResponseWriter, r *http.Request) {
	_, albumID, token, ok := scopedCaller(w, r)
	if !ok {
		return
	}
	var req struct {
		Kind        string  `json:"kind"`
		MediaID     *string `json:"media_id"`
		MemberToken string  `json:"member_token"`
		Sealed      string  `json:"sealed"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, reportBodyLimit)
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}
	in := service.ReportInput{Kind: req.Kind}
	if req.MediaID != nil {
		id, err := uuid.Parse(*req.MediaID)
		if err != nil {
			apierr.Write(w, r, apierr.Validation("invalid media_id").WithCause(err))
			return
		}
		in.MediaID = &id
	}
	var err error
	if req.MemberToken != "" {
		if in.MemberToken, err = base64.StdEncoding.DecodeString(req.MemberToken); err != nil {
			apierr.Write(w, r, apierr.Validation("member_token must be base64").WithCause(err))
			return
		}
	}
	if in.Sealed, err = base64.StdEncoding.DecodeString(req.Sealed); err != nil {
		apierr.Write(w, r, apierr.Validation("sealed must be base64").WithCause(err))
		return
	}
	id, err := h.reports.Submit(r.Context(), albumID, token, in)
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(map[string]any{"id": id})
}

// Block handles POST /albums/{id}/blocks
func (h *SafetyHandler) Block(w http.ResponseWriter, r *http.Request) {
	userID, albumID, _, ok := scopedCaller(w, r)
	if !ok {
		return
	}
	var req struct {
		MemberToken string `json:"member_token"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, blockBodyLimit)
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}
	target, err := base64.StdEncoding.DecodeString(req.MemberToken)
	if err != nil || len(target) == 0 {
		apierr.Write(w, r, apierr.Validation("member_token must be base64"))
		return
	}
	b, err := h.blocks.Block(r.Context(), albumID, userID, target)
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(blockJSON(b))
}

// ListBlocks handles GET /blocks. Names are kept on the phone, the server
// cannot say who a block is for
func (h *SafetyHandler) ListBlocks(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	blocks, err := h.blocks.List(r.Context(), userID)
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	out := make([]map[string]any, len(blocks))
	for i, b := range blocks {
		out[i] = blockJSON(b)
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"blocks": out})
}

// Unblock handles DELETE /blocks/{bid}
func (h *SafetyHandler) Unblock(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	id, err := uuid.Parse(mux.Vars(r)["bid"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid block id").WithCause(err))
		return
	}
	if err := h.blocks.Unblock(r.Context(), userID, id); err != nil {
		apierr.Write(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func blockJSON(b repository.Block) map[string]any {
	return map[string]any{"id": b.ID, "created_at": b.CreatedAt}
}
