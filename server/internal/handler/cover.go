package handler

import (
	"encoding/base64"
	"encoding/json"
	"net/http"

	"github.com/freytastic/miuchio/internal/apierr"
	"github.com/freytastic/miuchio/internal/middleware"
	"github.com/freytastic/miuchio/internal/model"
	"github.com/freytastic/miuchio/internal/service"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

// Every cover request is a few small fields, so the body is capped before
// it is decoded, ahead of the owner check
const coverBodyLimit = 4 << 10

type CoverHandler struct {
	svc *service.CoverService
}

func NewCoverHandler(svc *service.CoverService) *CoverHandler {
	return &CoverHandler{svc: svc}
}

// SetCover takes {"media_id": id} for one of the album's photos, or null to
// go back to the newest
func (h *CoverHandler) SetCover(w http.ResponseWriter, r *http.Request) {
	userID, albumID, token, ok := coverCaller(w, r)
	if !ok {
		return
	}
	var req struct {
		MediaID *string `json:"media_id"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, coverBodyLimit)
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}
	var mediaID *uuid.UUID
	if req.MediaID != nil {
		id, err := uuid.Parse(*req.MediaID)
		if err != nil {
			apierr.Write(w, r, apierr.Validation("invalid media_id").WithCause(err))
			return
		}
		mediaID = &id
	}
	if err := h.svc.SetMedia(r.Context(), albumID, userID, token, mediaID); err != nil {
		apierr.Write(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *CoverHandler) RequestUploadURL(w http.ResponseWriter, r *http.Request) {
	_, albumID, token, ok := coverCaller(w, r)
	if !ok {
		return
	}
	var req struct {
		CoverID    string `json:"cover_id"`
		BlobSize   int64  `json:"blob_size"`
		BlobSHA256 string `json:"blob_sha256"`
		KeyCT      string `json:"key_ct"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, coverBodyLimit)
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}
	coverID, err := uuid.Parse(req.CoverID)
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid cover_id").WithCause(err))
		return
	}
	sha, err := base64.StdEncoding.DecodeString(req.BlobSHA256)
	if err != nil {
		apierr.Write(w, r, apierr.Validation("blob_sha256 must be base64").WithCause(err))
		return
	}
	keyCT, err := base64.StdEncoding.DecodeString(req.KeyCT)
	if err != nil {
		apierr.Write(w, r, apierr.Validation("key_ct must be base64").WithCause(err))
		return
	}
	pre, err := h.svc.RequestUploadURL(r.Context(), albumID, token, service.CoverUploadInput{
		CoverID:    coverID,
		BlobSize:   req.BlobSize,
		BlobSHA256: sha,
		KeyCT:      keyCT,
	})
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"upload_url":      pre.URL,
		"required_header": pre.RequiredHeader,
	})
}

func (h *CoverHandler) Confirm(w http.ResponseWriter, r *http.Request) {
	userID, albumID, token, ok := coverCaller(w, r)
	if !ok {
		return
	}
	var req struct {
		CoverID string `json:"cover_id"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, coverBodyLimit)
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		apierr.Write(w, r, apierr.Validation("invalid request body").WithCause(err))
		return
	}
	coverID, err := uuid.Parse(req.CoverID)
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid cover_id").WithCause(err))
		return
	}
	if err := h.svc.Confirm(r.Context(), albumID, userID, token, coverID); err != nil {
		apierr.Write(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *CoverHandler) DownloadURL(w http.ResponseWriter, r *http.Request) {
	albumID, ok := scopedAlbumID(w, r)
	if !ok {
		return
	}
	coverID, err := uuid.Parse(mux.Vars(r)["cid"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid cover id").WithCause(err))
		return
	}
	res, err := h.svc.DownloadURL(r.Context(), albumID, coverID)
	if err != nil {
		apierr.Write(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"url":        res.URL,
		"expires_at": res.ExpiresAt.UTC().Format("2006-01-02T15:04:05Z07:00"),
	})
}

func coverCaller(w http.ResponseWriter, r *http.Request) (uuid.UUID, uuid.UUID, []byte, bool) {
	userID, ok := middleware.MustGetUserID(w, r)
	if !ok {
		return uuid.Nil, uuid.Nil, nil, false
	}
	albumID, ok := scopedAlbumID(w, r)
	if !ok {
		return uuid.Nil, uuid.Nil, nil, false
	}
	token, ok := middleware.MustGetMemberToken(r)
	if !ok {
		apierr.Write(w, r, apierr.Auth("member token missing in context"))
		return uuid.Nil, uuid.Nil, nil, false
	}
	return userID, albumID, token, true
}

// Storage coordinates stay server side, as with media and avatars
func coverJSON(c *model.CoverRef) any {
	if c == nil {
		return nil
	}
	out := map[string]any{
		"cover_id": c.CoverID,
		"set_by":   base64.StdEncoding.EncodeToString(c.SetBy),
	}
	if c.MediaID != nil {
		out["media_id"] = *c.MediaID
		return out
	}
	out["blob_size"] = c.BlobSize
	out["blob_sha256"] = base64.StdEncoding.EncodeToString(c.BlobSHA256)
	out["key_ct"] = base64.StdEncoding.EncodeToString(c.KeyCT)
	return out
}
