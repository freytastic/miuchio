package service

import (
	"context"
	"errors"
	"testing"

	"github.com/freytastic/miuchio/internal/model"
	"github.com/freytastic/miuchio/internal/repository"
	"github.com/google/uuid"
)

// removeMemberStore mocks the RemoveMember authorization surface. The revoke
// itself is one locked repo call, RevokeMemberTx
type removeMemberStore struct {
	lookupFn   func(ctx context.Context, userID, albumID uuid.UUID) ([]byte, string, error)
	revokeTxFn func(ctx context.Context, albumID uuid.UUID, callerToken, targetToken []byte) (role string, alreadyRevoked bool, err error)

	revokedToken []byte // captures the target token passed to RevokeMemberTx
	revokedMedia repository.DepartingMedia
	revokeCalls  int
	deleteCalls  int
	deleteErr    error
	removal      repository.AlbumRemoval
}

func (m *removeMemberStore) LookupMember(ctx context.Context, userID, albumID uuid.UUID) ([]byte, string, error) {
	return m.lookupFn(ctx, userID, albumID)
}
func (m *removeMemberStore) RevokeMemberTx(ctx context.Context, albumID uuid.UUID, callerToken, targetToken []byte, media repository.DepartingMedia) (repository.Revocation, error) {
	m.revokeCalls++
	m.revokedToken = targetToken
	m.revokedMedia = media
	role, already, err := m.revokeTxFn(ctx, albumID, callerToken, targetToken)
	return repository.Revocation{Role: role, AlreadyRevoked: already}, err
}

// unused AlbumStore methods
func (m *removeMemberStore) CreateWithAdmin(context.Context, []byte, uuid.UUID) (*model.Album, []byte, error) {
	return nil, nil, nil
}
func (m *removeMemberStore) GetByID(context.Context, uuid.UUID) (*model.Album, error) {
	return nil, nil
}
func (m *removeMemberStore) ListForUser(context.Context, uuid.UUID) ([]model.AlbumWithMemberInfo, error) {
	return nil, nil
}
func (m *removeMemberStore) ListMembers(context.Context, uuid.UUID) ([]model.MemberWithProfile, error) {
	return nil, nil
}
func (m *removeMemberStore) UpdateName(context.Context, uuid.UUID, []byte) error   { return nil }
func (m *removeMemberStore) SetCover(context.Context, uuid.UUID, *uuid.UUID) error { return nil }
func (m *removeMemberStore) UpdateMemberNameCT(context.Context, uuid.UUID, []byte, []byte) error {
	return nil
}
func (m *removeMemberStore) DeleteAlbumTx(context.Context, uuid.UUID, []byte) (repository.AlbumRemoval, error) {
	m.deleteCalls++
	if m.deleteErr != nil {
		return repository.AlbumRemoval{}, m.deleteErr
	}
	return m.removal, nil
}

type recordingCleaner struct{ keys []string }

func (c *recordingCleaner) CleanupObjectKeys(_ context.Context, keys []string) {
	c.keys = append(c.keys, keys...)
}

func okRevoke(role string) func(context.Context, uuid.UUID, []byte, []byte) (string, bool, error) {
	return func(context.Context, uuid.UUID, []byte, []byte) (string, bool, error) { return role, false, nil }
}

func TestRemoveMember_AdminKicksMember(t *testing.T) {
	albumID := uuid.New()
	admin := []byte("adminadminadminadminadminadmin32")
	target := []byte("targettargettargettargettarget32")
	store := &removeMemberStore{
		lookupFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return admin, "admin", nil
		},
		revokeTxFn: okRevoke("member"),
	}
	svc := NewAlbumService(store)

	res, err := svc.RemoveMember(context.Background(), albumID, uuid.New(), target, false)
	if err != nil {
		t.Fatalf("RemoveMember: unexpected error %v", err)
	}
	if res.AlreadyRevoked {
		t.Errorf("AlreadyRevoked = true, want false")
	}
	if store.revokeCalls != 1 {
		t.Fatalf("RevokeMemberTx calls = %d, want 1", store.revokeCalls)
	}
	if string(store.revokedToken) != string(target) {
		t.Errorf("revoked token = %q, want target", store.revokedToken)
	}
}

func TestRemoveMember_PlainMemberCannotKickOther(t *testing.T) {
	target := []byte("targettargettargettargettarget32")
	store := &removeMemberStore{
		lookupFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return []byte("callercallercallercallercaller32"), "member", nil
		},
		revokeTxFn: func(context.Context, uuid.UUID, []byte, []byte) (string, bool, error) {
			t.Fatal("RevokeMemberTx must not be called for an unauthorized caller")
			return "", false, nil
		},
	}
	svc := NewAlbumService(store)

	_, err := svc.RemoveMember(context.Background(), uuid.New(), uuid.New(), target, false)
	if !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("err = %v, want ErrUnauthorized", err)
	}
	if store.revokeCalls != 0 {
		t.Errorf("RevokeMemberTx should not be called, got %d", store.revokeCalls)
	}
}

// The dormant co-admin string grants no removal or rename authority
func TestCoAdmin_HasNoAdminAuthority(t *testing.T) {
	store := &removeMemberStore{
		lookupFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return []byte("callercallercallercallercaller32"), "co-admin", nil
		},
		revokeTxFn: func(context.Context, uuid.UUID, []byte, []byte) (string, bool, error) {
			t.Fatal("RevokeMemberTx must not be called for a co-admin")
			return "", false, nil
		},
	}
	svc := NewAlbumService(store)

	_, err := svc.RemoveMember(context.Background(), uuid.New(), uuid.New(),
		[]byte("targettargettargettargettarget32"), false)
	if !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("remove: err = %v, want ErrUnauthorized", err)
	}
	if err := svc.UpdateAlbum(context.Background(), uuid.New(), uuid.New(), []byte("name")); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("rename: err = %v, want ErrUnauthorized", err)
	}
}

// Authorization runs before the already revoked no op, so a non admin gets
// unauthorized instead of a 204 and the revoke transaction is never reached
func TestRemoveMember_PlainMemberCannotRemoveAlreadyRevoked(t *testing.T) {
	store := &removeMemberStore{
		lookupFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return []byte("callercallercallercallercaller32"), "member", nil
		},
		revokeTxFn: func(context.Context, uuid.UUID, []byte, []byte) (string, bool, error) {
			t.Fatal("RevokeMemberTx must not be reached before the authz check")
			return "member", true, nil
		},
	}
	svc := NewAlbumService(store)

	_, err := svc.RemoveMember(context.Background(), uuid.New(), uuid.New(),
		[]byte("targettargettargettargettarget32"), false)
	if !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("err = %v, want ErrUnauthorized (authz before no-op)", err)
	}
}

func TestRemoveMember_MemberCanLeave(t *testing.T) {
	self := []byte("selfselfselfselfselfselfselfsel1")
	store := &removeMemberStore{
		lookupFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return self, "member", nil
		},
		revokeTxFn: okRevoke("member"),
	}
	svc := NewAlbumService(store)

	_, err := svc.RemoveMember(context.Background(), uuid.New(), uuid.New(), self, false)
	if err != nil {
		t.Fatalf("self-leave: unexpected error %v", err)
	}
	if store.revokeCalls != 1 {
		t.Errorf("RevokeMemberTx calls = %d, want 1", store.revokeCalls)
	}
}

// Only the leaver picks, an admin's flag must never override the target's setting
func TestRemoveMember_MediaPolicy(t *testing.T) {
	self := []byte("selfselfselfselfselfselfselfsel1")
	other := []byte("targettargettargettargettarget32")
	cases := []struct {
		name        string
		role        string
		target      []byte
		deleteMedia bool
		want        repository.DepartingMedia
	}{
		{"leave keeps", "member", self, false, repository.KeepMedia},
		{"leave deletes", "member", self, true, repository.DeleteMedia},
		{"kick follows setting", "admin", other, false, repository.PreferredMedia},
		{"kick ignores flag", "admin", other, true, repository.PreferredMedia},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			store := &removeMemberStore{
				lookupFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
					return self, tc.role, nil
				},
				revokeTxFn: okRevoke("member"),
			}
			svc := NewAlbumService(store)
			if _, err := svc.RemoveMember(context.Background(), uuid.New(), uuid.New(), tc.target, tc.deleteMedia); err != nil {
				t.Fatalf("unexpected error %v", err)
			}
			if store.revokedMedia != tc.want {
				t.Errorf("media = %v, want %v", store.revokedMedia, tc.want)
			}
		})
	}
}

func TestRemoveMember_LastAdminRejectedByTx(t *testing.T) {
	self := []byte("adminadminadminadminadminadmin32")
	store := &removeMemberStore{
		lookupFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return self, "admin", nil
		},
		revokeTxFn: func(context.Context, uuid.UUID, []byte, []byte) (string, bool, error) {
			return "admin", false, repository.ErrLastAdmin
		},
	}
	svc := NewAlbumService(store)

	_, err := svc.RemoveMember(context.Background(), uuid.New(), uuid.New(), self, false)
	if !errors.Is(err, ErrLastAdmin) {
		t.Fatalf("err = %v, want ErrLastAdmin", err)
	}
}

func TestRemoveMember_TargetNotFound(t *testing.T) {
	store := &removeMemberStore{
		lookupFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return []byte("adminadminadminadminadminadmin32"), "admin", nil
		},
		revokeTxFn: func(context.Context, uuid.UUID, []byte, []byte) (string, bool, error) {
			return "", false, repository.ErrMemberNotFound
		},
	}
	svc := NewAlbumService(store)

	_, err := svc.RemoveMember(context.Background(), uuid.New(), uuid.New(),
		[]byte("ghostghostghostghostghostghost32"), false)
	if !errors.Is(err, ErrMemberNotFound) {
		t.Fatalf("err = %v, want ErrMemberNotFound", err)
	}
}

func TestRemoveMember_AlreadyRevokedIsNoOp(t *testing.T) {
	target := []byte("targettargettargettargettarget32")
	store := &removeMemberStore{
		lookupFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return []byte("adminadminadminadminadminadmin32"), "admin", nil
		},
		revokeTxFn: func(context.Context, uuid.UUID, []byte, []byte) (string, bool, error) {
			return "member", true, nil // already revoked
		},
	}
	svc := NewAlbumService(store)

	res, err := svc.RemoveMember(context.Background(), uuid.New(), uuid.New(), target, false)
	if err != nil {
		t.Fatalf("already-revoked: unexpected error %v", err)
	}
	if !res.AlreadyRevoked {
		t.Errorf("AlreadyRevoked = false, want true")
	}
}

func TestDeleteAlbum_ReturnsMembersAndCleansQueuedObjects(t *testing.T) {
	member := uuid.New()
	store := &removeMemberStore{
		lookupFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return []byte("adminadminadminadminadminadmin32"), "admin", nil
		},
		removal: repository.AlbumRemoval{MemberUserIDs: []uuid.UUID{member}, Keys: []string{"blob", "thumb"}},
	}
	svc := NewAlbumService(store)
	cleaner := &recordingCleaner{}
	svc.SetObjectCleaner(cleaner)

	members, err := svc.DeleteAlbum(context.Background(), uuid.New(), uuid.New())
	if err != nil {
		t.Fatalf("DeleteAlbum: %v", err)
	}
	if len(members) != 1 || members[0] != member {
		t.Errorf("members = %v, want [%s]", members, member)
	}
	if len(cleaner.keys) != 2 {
		t.Errorf("cleaned keys = %v, want both queued objects", cleaner.keys)
	}
}

func TestDeleteAlbum_OnlyTheAdmin(t *testing.T) {
	for _, role := range []string{"member", "co-admin"} {
		store := &removeMemberStore{
			lookupFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
				return []byte("callercallercallercallercaller32"), role, nil
			},
		}
		svc := NewAlbumService(store)
		if _, err := svc.DeleteAlbum(context.Background(), uuid.New(), uuid.New()); !errors.Is(err, ErrUnauthorized) {
			t.Fatalf("%s: err = %v, want ErrUnauthorized", role, err)
		}
		if store.deleteCalls != 0 {
			t.Fatalf("%s: delete reached the repository", role)
		}
	}
}

func TestDeleteAlbum_AdminRemovedMidFlight(t *testing.T) {
	store := &removeMemberStore{
		lookupFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return []byte("adminadminadminadminadminadmin32"), "admin", nil
		},
		deleteErr: repository.ErrCallerRevoked,
	}
	svc := NewAlbumService(store)
	if _, err := svc.DeleteAlbum(context.Background(), uuid.New(), uuid.New()); !errors.Is(err, ErrCallerRevoked) {
		t.Fatalf("err = %v, want ErrCallerRevoked", err)
	}
}

// A concurrent removal can revoke the caller after the unlocked role check. The
// transaction reports ErrCallerRevoked, which becomes E_MEMBER_REVOKED
func TestRemoveMember_CallerRevokedMidFlight(t *testing.T) {
	store := &removeMemberStore{
		lookupFn: func(context.Context, uuid.UUID, uuid.UUID) ([]byte, string, error) {
			return []byte("adminadminadminadminadminadmin32"), "admin", nil
		},
		revokeTxFn: func(context.Context, uuid.UUID, []byte, []byte) (string, bool, error) {
			return "", false, repository.ErrCallerRevoked
		},
	}
	svc := NewAlbumService(store)

	_, err := svc.RemoveMember(context.Background(), uuid.New(), uuid.New(),
		[]byte("targettargettargettargettarget32"), false)
	if !errors.Is(err, ErrCallerRevoked) {
		t.Fatalf("err = %v, want ErrCallerRevoked", err)
	}
}
