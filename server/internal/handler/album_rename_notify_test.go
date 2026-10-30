package handler

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/freytastic/miuchio/internal/middleware"
	"github.com/freytastic/miuchio/internal/model"
	"github.com/freytastic/miuchio/internal/service"
	"github.com/freytastic/miuchio/internal/ws"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

func renameRouter(store *mockAlbumStore, notifier *mockNotifier, resolver *mockResolver) http.Handler {
	h := NewAlbumHandler(service.NewAlbumService(store), notifier, resolver)
	r := mux.NewRouter()
	r.HandleFunc("/api/v1/albums/{id}", h.UpdateAlbum).Methods(http.MethodPatch)
	return r
}

func doRename(h http.Handler, albumID uuid.UUID) *httptest.ResponseRecorder {
	body := bytes.NewBufferString(`{"name_ct":"c2VhbGVkLW5hbWU="}`)
	req := httptest.NewRequest(http.MethodPatch, "/api/v1/albums/"+albumID.String(), body)
	req = req.WithContext(context.WithValue(req.Context(), middleware.UserIDKey, uuid.New()))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestUpdateAlbum_RenameTellsActiveMembersOnlyTheAlbum(t *testing.T) {
	albumID := uuid.New()
	admin := []byte("adminadminadminadminadminadmin32")
	member := []byte("membermembermembermembermember32")
	gone := []byte("gonegonegonegonegonegonegonegon3")
	users := []uuid.UUID{uuid.New(), uuid.New()}

	store := &mockAlbumStore{
		lookupMemberFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return admin, "admin", nil
		},
		listMembersFn: func(context.Context, uuid.UUID) ([]model.MemberWithProfile, error) {
			return []model.MemberWithProfile{
				{MemberToken: admin, Role: "admin"},
				{MemberToken: member, Role: "member"},
				{MemberToken: gone, Role: "member", Revoked: true},
			}, nil
		},
	}
	var asked [][]byte
	resolver := &mockResolver{fn: func(_ context.Context, tokens [][]byte) ([]uuid.UUID, error) {
		asked = tokens
		return users, nil
	}}
	notifier := &mockNotifier{}

	rec := doRename(renameRouter(store, notifier, resolver), albumID)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204", rec.Code)
	}
	if len(asked) != 2 {
		t.Fatalf("resolved %d tokens, want the 2 active members", len(asked))
	}
	for _, tok := range asked {
		if bytes.Equal(tok, gone) {
			t.Errorf("a revoked member was told about the rename")
		}
	}
	if len(notifier.calls) != 1 {
		t.Fatalf("emit calls = %d, want 1", len(notifier.calls))
	}
	c := notifier.calls[0]
	if c.typ != ws.EventAlbumRenamed {
		t.Errorf("event type = %q, want %q", c.typ, ws.EventAlbumRenamed)
	}
	payload, ok := c.payload.(map[string]any)
	if !ok || len(payload) != 1 || payload["album_id"] != albumID.String() {
		t.Errorf("payload = %v, want only the album id", c.payload)
	}
}

func TestUpdateAlbum_RefusedRenameTellsNoOne(t *testing.T) {
	store := &mockAlbumStore{
		lookupMemberFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return []byte("membermembermembermembermember32"), "member", nil
		},
	}
	notifier := &mockNotifier{}

	rec := doRename(renameRouter(store, notifier, &mockResolver{}), uuid.New())

	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}
	if len(notifier.calls) != 0 {
		t.Errorf("emit calls = %d, want none", len(notifier.calls))
	}
}
