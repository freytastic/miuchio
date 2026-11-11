package handler

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/freytastic/miuchio/internal/apierr"
	"github.com/freytastic/miuchio/internal/e2ee/authority"
	"github.com/freytastic/miuchio/internal/middleware"
	"github.com/freytastic/miuchio/internal/repository"
	"github.com/freytastic/miuchio/internal/ws"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

type handoverReq struct {
	NewAdminToken string `json:"new_admin_token"`
	Term          uint32 `json:"term"`
	Mode          byte   `json:"mode"`
	DeleteMedia   bool   `json:"delete_media"`
	Sig           string `json:"sig"`
	OperationID   string `json:"operation_id"`
}

// Handover handles POST /api/v1/albums/{id}/handover
func (h *AlbumHandler) Handover(w http.ResponseWriter, r *http.Request) {
	albumID, err := uuid.Parse(mux.Vars(r)["id"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid album id").WithCause(err))
		return
	}
	callerToken, ok := middleware.MustGetMemberToken(r)
	if !ok {
		apierr.Write(w, r, apierr.Auth("missing member context"))
		return
	}
	var req handoverReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}
	newToken, err := base64.StdEncoding.DecodeString(req.NewAdminToken)
	if err != nil || len(newToken) != authority.TokenLen {
		apierr.Write(w, r, apierr.Validation("new_admin_token must be 32 bytes of base64"))
		return
	}
	sig, err := base64.StdEncoding.DecodeString(req.Sig)
	if err != nil || len(sig) != ed25519.SignatureSize {
		apierr.Write(w, r, apierr.Validation("sig must be 64 bytes of base64"))
		return
	}
	operationID, err := uuid.Parse(req.OperationID)
	if err != nil {
		apierr.Write(w, r, apierr.Validation("operation_id must be a uuid"))
		return
	}
	if req.Mode != authority.ModeStay && req.Mode != authority.ModeLeave {
		apierr.Write(w, r, apierr.Validation("mode must be 1 (stay) or 2 (leave)"))
		return
	}
	if req.DeleteMedia && req.Mode != authority.ModeLeave {
		apierr.Write(w, r, apierr.Validation("delete_media only applies when leaving"))
		return
	}

	res, err := h.albumService.Handover(r.Context(), repository.HandoverRequest{
		AlbumID:     albumID,
		CallerToken: callerToken,
		NewToken:    newToken,
		Term:        req.Term,
		Mode:        req.Mode,
		DeleteMedia: req.DeleteMedia,
		Sig:         sig,
		OperationID: operationID,
	})
	if err != nil {
		switch {
		case errors.Is(err, repository.ErrCallerRevoked):
			apierr.Write(w, r, apierr.MemberRevoked("your access to this album has been revoked"))
		case errors.Is(err, repository.ErrNotAlbumAdmin):
			apierr.Write(w, r, apierr.Forbidden("only the admin can hand the album over"))
		case errors.Is(err, repository.ErrStaleTerm):
			apierr.Write(w, r, apierr.Conflict("the album already has a newer admin"))
		case errors.Is(err, repository.ErrSuccessorIneligible):
			apierr.Write(w, r, apierr.SuccessorIneligible("this member cannot take the album right now"))
		case errors.Is(err, repository.ErrHandoverSig):
			apierr.Write(w, r, apierr.SigInvalid("handover signature verification failed"))
		case errors.Is(err, repository.ErrHandoverReused):
			apierr.Write(w, r, apierr.Conflict("operation_id was used for a different handover"))
		case errors.Is(err, repository.ErrAlbumNotFound):
			apierr.Write(w, r, apierr.NotFound("album not found"))
		default:
			apierr.Write(w, r, apierr.Internal("failed to hand the album over").WithCause(err))
		}
		return
	}

	if res.Committed {
		h.notifyAdminChanged(r.Context(), albumID, res)
	}
	writeHandover(w, albumID, res.Mode)
}

// HandoverOutcome handles GET /api/v1/album-handovers/{operation_id}. It's
// outside the album scope because leaving ends the caller's membership
func (h *AlbumHandler) HandoverOutcome(w http.ResponseWriter, r *http.Request) {
	operationID, err := uuid.Parse(mux.Vars(r)["operation_id"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("operation_id must be a uuid"))
		return
	}
	albumID, mode, err := h.albumService.HandoverOutcome(r.Context(), operationID)
	if errors.Is(err, repository.ErrHandoverNotFound) {
		apierr.Write(w, r, apierr.NotFound("no such handover"))
		return
	}
	if err != nil {
		apierr.Write(w, r, apierr.Internal("handover lookup failed").WithCause(err))
		return
	}
	writeHandover(w, albumID, mode)
}

func writeHandover(w http.ResponseWriter, albumID uuid.UUID, mode byte) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"album_id": albumID.String(),
		"mode":     mode,
	})
}

// Notification failures cannot roll back the committed handover
func (h *AlbumHandler) notifyAdminChanged(ctx context.Context, albumID uuid.UUID, res repository.HandoverResult) {
	if h.notifier == nil || h.resolver == nil {
		return
	}
	tokens := [][]byte{res.OldToken}
	if members, err := h.albumService.ListMembers(ctx, albumID); err == nil {
		for _, m := range members {
			if !m.Revoked {
				tokens = append(tokens, m.MemberToken)
			}
		}
	}
	if users, err := h.resolver.UserIDsByMemberTokens(ctx, tokens); err == nil && len(users) > 0 {
		_ = h.notifier.EmitToUsers(ctx, users, ws.EventAdminChanged, map[string]any{
			"album_id": albumID.String(),
			"term":     res.Term,
		})
	}
	if res.Mode == authority.ModeLeave {
		h.notifyRevoked(ctx, albumID, res.OldToken, res.Media.MediaIDs)
	}
}
