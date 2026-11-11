package repository_test

import (
	"context"
	"errors"
	"sync"
	"testing"

	"github.com/freytastic/miuchio/internal/e2ee/epoch"
	"github.com/freytastic/miuchio/internal/repository"
)

// A second admin row only exists in legacy data, but it is the one way a
// signer can be removed while the album keeps an admin to authorize it
func (e *rotationEnv) secondSigner(t *testing.T, role string) []byte {
	t.Helper()
	tok, err := e.repo.AddMember(context.Background(), e.album, e.seedUser(t), role)
	if err != nil {
		t.Fatalf("add %s: %v", role, err)
	}
	if _, err := e.pool.Exec(context.Background(),
		`INSERT INTO member_notes (album_id, member_token, generation, issuer_term, ik_pub, lk_pub, sig)
		 VALUES ($1, $2, 1, 0, $3, $3, $4)`,
		e.album, tok, make([]byte, 32), make([]byte, 64)); err != nil {
		t.Fatalf("seed note: %v", err)
	}
	return tok
}

func (e *rotationEnv) signedBy(n int, signer []byte, recipients ...[]byte) epoch.InsertEpochInput {
	in := e.epochInput(n, recipients...)
	in.SenderToken = signer
	return in
}

func TestInsertEpoch_RefusesARemovedSigner(t *testing.T) {
	e := newRotationEnv(t)
	signer := e.secondSigner(t, "admin")
	if _, err := e.repo.RevokeMemberTx(context.Background(), e.album, e.admin, signer, repository.KeepMedia); err != nil {
		t.Fatalf("revoke: %v", err)
	}

	// The remaining set is exact, so only the signer check can refuse this
	err := e.epochs.InsertEpoch(context.Background(), e.signedBy(1, signer, e.admin, e.member))
	if !errors.Is(err, epoch.ErrCallerRevoked) {
		t.Fatalf("got %v, want ErrCallerRevoked", err)
	}
	if !e.required(t) {
		t.Fatal("a refused epoch must leave the rotation owed")
	}
}

// Membership alone is not signing authority, the admin's note is
func TestInsertEpoch_RefusesASignerWithoutANote(t *testing.T) {
	e := newRotationEnv(t)
	if _, err := e.pool.Exec(context.Background(),
		`UPDATE albums SET rotation_required = TRUE WHERE id = $1`, e.album); err != nil {
		t.Fatal(err)
	}

	err := e.epochs.InsertEpoch(context.Background(), e.signedBy(1, e.member, e.admin, e.member))
	if !errors.Is(err, epoch.ErrCallerNoNote) {
		t.Fatalf("got %v, want ErrCallerNoNote", err)
	}
	if !e.required(t) {
		t.Fatal("a refused epoch must leave the rotation owed")
	}
}

func TestInsertEpoch_RefusesAMemberWhenNothingIsOwed(t *testing.T) {
	e := newRotationEnv(t)
	signer := e.secondSigner(t, "member")
	e.rotate(t, 1, e.admin, e.member, signer)

	err := e.epochs.InsertEpoch(context.Background(), e.signedBy(2, signer, e.admin, e.member, signer))
	if !errors.Is(err, epoch.ErrRotationNotOwed) {
		t.Fatalf("got %v, want ErrRotationNotOwed", err)
	}
}

// A removed signer's rotation must never commit, whichever transaction wins
func TestInsertEpoch_RaceWithRemovalNeverKeysTheRemovedSigner(t *testing.T) {
	for i := range 25 {
		e := newRotationEnv(t)
		ctx := context.Background()
		signer := e.secondSigner(t, "admin")

		var rotateErr, revokeErr error
		var wg sync.WaitGroup
		start := make(chan struct{})
		wg.Add(2)
		go func() {
			defer wg.Done()
			<-start
			rotateErr = e.epochs.InsertEpoch(ctx, e.signedBy(1, signer, e.admin, e.member))
		}()
		go func() {
			defer wg.Done()
			<-start
			_, revokeErr = e.repo.RevokeMemberTx(ctx, e.album, e.admin, signer, repository.KeepMedia)
		}()
		close(start)
		wg.Wait()

		if revokeErr != nil {
			t.Fatalf("round %d: revoke: %v", i, revokeErr)
		}
		if rotateErr == nil {
			t.Fatalf("round %d: the removed signer minted the next key", i)
		}
		if !errors.Is(rotateErr, epoch.ErrCallerRevoked) && !errors.Is(rotateErr, epoch.ErrMemberSetDrift) {
			t.Fatalf("round %d: got %v, want a revoked signer or member set drift", i, rotateErr)
		}
	}
}
