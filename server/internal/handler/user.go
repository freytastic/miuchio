package handler

import (
	"encoding/json"
	"net/http"

	"github.com/freytastic/miuchio/internal/apierr"
	"github.com/freytastic/miuchio/internal/middleware"
	"github.com/freytastic/miuchio/internal/service"
)

type UserHandler struct {
	userService *service.UserService
}

func NewUserHandler(s *service.UserService) *UserHandler {
	return &UserHandler{userService: s}
}

func (h *UserHandler) GetMe(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	u, err := h.userService.GetUserByID(r.Context(), userID)
	if err != nil {
		apierr.Write(w, r, apierr.NotFound("user not found").WithCause(err))
		return
	}
	// Email, name and avatar are absent on purpose: the server keeps only an email
	// HMAC, and names and avatars live encrypted per album. miuchio_id is the
	// user's own shareable handle
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"id":                    u.ID,
		"miuchio_id":            u.MiuchioID,
		"delete_media_on_leave": u.DeleteMediaOnLeave,
		"created_at":            u.CreatedAt,
		"updated_at":            u.UpdatedAt,
	})
}

func (h *UserHandler) UpdatePreferences(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return
	}
	var req struct {
		DeleteMediaOnLeave *bool `json:"delete_media_on_leave"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}
	if req.DeleteMediaOnLeave == nil {
		apierr.Write(w, r, apierr.Validation("delete_media_on_leave is required"))
		return
	}
	if err := h.userService.SetDeleteMediaOnLeave(r.Context(), userID, *req.DeleteMediaOnLeave); err != nil {
		apierr.Write(w, r, apierr.Internal("failed to update preferences").WithCause(err))
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
