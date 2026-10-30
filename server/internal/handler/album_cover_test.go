package handler

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/freytastic/miuchio/internal/middleware"
	"github.com/freytastic/miuchio/internal/model"
	"github.com/freytastic/miuchio/internal/repository"
	"github.com/freytastic/miuchio/internal/service"
	"github.com/freytastic/miuchio/internal/ws"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

func coverRouter(store *mockAlbumStore, notifier *mockNotifier, resolver *mockResolver) http.Handler {
	h := NewAlbumHandler(service.NewAlbumService(store), notifier, resolver)
	r := mux.NewRouter()
	r.HandleFunc("/api/v1/albums/{id}/cover", h.SetCover).Methods(http.MethodPut)
	return r
}

func doCover(h http.Handler, albumID uuid.UUID, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPut,
		"/api/v1/albums/"+albumID.String()+"/cover", bytes.NewBufferString(body))
	req = req.WithContext(context.WithValue(req.Context(), middleware.UserIDKey, uuid.New()))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func asRole(role string) func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
	return func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
		return []byte("membermembermembermembermember32"), role, nil
	}
}

func TestSetCover_OwnerChoosesAndMembersHear(t *testing.T) {
	media := uuid.New()
	store := &mockAlbumStore{
		lookupMemberFn: asRole("admin"),
		listMembersFn: func(context.Context, uuid.UUID) ([]model.MemberWithProfile, error) {
			return []model.MemberWithProfile{{MemberToken: []byte("t")}}, nil
		},
	}
	notifier := &mockNotifier{}
	resolver := &mockResolver{fn: func(context.Context, [][]byte) ([]uuid.UUID, error) {
		return []uuid.UUID{uuid.New()}, nil
	}}

	rec := doCover(coverRouter(store, notifier, resolver), uuid.New(),
		`{"media_id":"`+media.String()+`"}`)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204", rec.Code)
	}
	if store.cover == nil || *store.cover != media {
		t.Fatalf("cover = %v, want %v", store.cover, media)
	}
	if len(notifier.calls) != 1 || notifier.calls[0].typ != ws.EventAlbumUpdated {
		t.Fatalf("calls = %+v, want one album_updated", notifier.calls)
	}
}

func TestSetCover_NullGoesBackToNewest(t *testing.T) {
	store := &mockAlbumStore{
		lookupMemberFn: asRole("admin"),
		listMembersFn:  func(context.Context, uuid.UUID) ([]model.MemberWithProfile, error) { return nil, nil },
		cover:          &uuid.UUID{},
	}

	rec := doCover(coverRouter(store, &mockNotifier{}, &mockResolver{}), uuid.New(),
		`{"media_id":null}`)

	if rec.Code != http.StatusNoContent || store.cover != nil {
		t.Fatalf("status = %d cover = %v, want 204 and nil", rec.Code, store.cover)
	}
}

func TestSetCover_OnlyTheOwner(t *testing.T) {
	store := &mockAlbumStore{lookupMemberFn: asRole("member")}
	notifier := &mockNotifier{}

	rec := doCover(coverRouter(store, notifier, &mockResolver{}), uuid.New(),
		`{"media_id":"`+uuid.New().String()+`"}`)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}
	if store.cover != nil || len(notifier.calls) != 0 {
		t.Fatalf("a refused cover changed or announced something")
	}
}

func TestSetCover_PhotoFromAnotherAlbumIsRefused(t *testing.T) {
	store := &mockAlbumStore{
		lookupMemberFn: asRole("admin"),
		coverErr:       repository.ErrMediaNotFound,
	}
	notifier := &mockNotifier{}

	rec := doCover(coverRouter(store, notifier, &mockResolver{}), uuid.New(),
		`{"media_id":"`+uuid.New().String()+`"}`)

	if rec.Code != http.StatusBadRequest && rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want a validation error", rec.Code)
	}
	if len(notifier.calls) != 0 {
		t.Fatalf("a refused cover was announced")
	}
}
