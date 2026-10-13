package handler

import (
	"net/http"

	"github.com/freytastic/miuchio/internal/apierr"
)

// Placeholders for invite links, which are not built yet. Existing users are
// invited through internal/e2ee/invite

type InviteHandler struct{}

func NewInviteHandler() *InviteHandler { return &InviteHandler{} }

func (h *InviteHandler) CreateInvite(w http.ResponseWriter, r *http.Request) {
	apierr.Write(w, r, apierr.NotImplemented("invite creation is not available yet"))
}

func (h *InviteHandler) GetPreview(w http.ResponseWriter, r *http.Request) {
	apierr.Write(w, r, apierr.NotImplemented("invite preview is not available yet"))
}

func (h *InviteHandler) JoinAlbum(w http.ResponseWriter, r *http.Request) {
	apierr.Write(w, r, apierr.NotImplemented("join via invite is not available yet"))
}

func (h *InviteHandler) CreateInviteBlob(w http.ResponseWriter, r *http.Request) {
	apierr.Write(w, r, apierr.NotImplemented("invite blob creation is not available yet"))
}

func (h *InviteHandler) GetInviteBlob(w http.ResponseWriter, r *http.Request) {
	apierr.Write(w, r, apierr.NotImplemented("invite blob fetch is not available yet"))
}
