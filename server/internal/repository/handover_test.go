package repository_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"sync"
	"testing"

	"github.com/freytastic/miuchio/internal/e2ee/authority"
	"github.com/freytastic/miuchio/internal/repository"
	"github.com/google/uuid"
)

// An album whose member has joined and holds a note, so it can be handed to
type handoverEnv struct {
	*rotationEnv
	keys map[string]ed25519.PrivateKey
}

func newHandoverEnv(t *testing.T) *handoverEnv {
	t.Helper()
	e := &handoverEnv{rotationEnv: newRotationEnv(t), keys: map[string]ed25519.PrivateKey{}}
	e.giveKey(t, e.owner, e.admin)
	e.makeEligible(t, e.member)
	return e
}

func (e *handoverEnv) giveKey(t *testing.T, userID uuid.UUID, token []byte) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(context.Background(),
		`UPDATE users SET ik_pub = $2 WHERE id = $1`, userID, []byte(pub)); err != nil {
		t.Fatal(err)
	}
	e.keys[string(token)] = priv
}

func (e *handoverEnv) makeEligible(t *testing.T, token []byte) {
	t.Helper()
	ctx := context.Background()
	if _, err := e.pool.Exec(ctx,
		`UPDATE album_members SET acked_joins = joins WHERE member_token = $1`, token); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx,
		`INSERT INTO member_notes (album_id, member_token, generation, issuer_term, ik_pub, lk_pub, sig)
		 VALUES ($1, $2, 1, 0, $3, $3, $4) ON CONFLICT DO NOTHING`,
		e.album, token, make([]byte, 32), make([]byte, 64)); err != nil {
		t.Fatal(err)
	}
}

// Signs what an honest phone would: the chain tip and the successor's
// published keys as the album holds them now
func (e *handoverEnv) request(t *testing.T, from, to []byte, term uint32, mode byte, deleteMedia bool) repository.HandoverRequest {
	t.Helper()
	ctx := context.Background()
	h := authority.Handover{
		AlbumID: e.album, Term: term, PrevHash: authority.ZeroHash,
		OldToken: from, NewToken: to, NewGeneration: 1, Mode: mode, DeleteMedia: deleteMedia,
		NewIKPub: make([]byte, 32), NewLKPub: make([]byte, 32),
	}
	chain, err := authority.NewRepo(e.pool).Handovers(ctx, e.album)
	if err != nil {
		t.Fatal(err)
	}
	if n := len(chain); n > 0 {
		h.PrevHash = authority.HandoverHash(authority.HandoverMsg(chain[n-1].Handover), chain[n-1].Sig)
	}
	for _, m := range e.members(t) {
		if string(m.MemberToken) == string(to) && m.Profile.IKPub != nil {
			h.NewIKPub, h.NewLKPub = m.Profile.IKPub, m.Profile.LKPub
		}
	}
	return repository.HandoverRequest{
		AlbumID: e.album, CallerToken: from, NewToken: to, Term: term,
		Mode: mode, DeleteMedia: deleteMedia, OperationID: uuid.New(),
		Sig: ed25519.Sign(e.keys[string(from)], authority.HandoverMsg(h)),
	}
}

func (e *handoverEnv) roleOf(t *testing.T, token []byte) (role string, revoked bool) {
	t.Helper()
	if err := e.pool.QueryRow(context.Background(),
		`SELECT role, revoked_at IS NOT NULL FROM album_members
		 WHERE album_id = $1 AND member_token = $2`, e.album, token).Scan(&role, &revoked); err != nil {
		t.Fatal(err)
	}
	return
}

func (e *handoverEnv) term(t *testing.T) int {
	t.Helper()
	var term int
	if err := e.pool.QueryRow(context.Background(),
		`SELECT admin_term FROM albums WHERE id = $1`, e.album).Scan(&term); err != nil {
		t.Fatal(err)
	}
	return term
}

func TestHandover_StayMovesEveryAdminPower(t *testing.T) {
	e := newHandoverEnv(t)
	ctx := context.Background()
	third := e.secondSigner(t, "member")
	e.rotate(t, 1, e.admin, e.member, third)

	res, err := e.repo.HandoverTx(ctx, e.request(t, e.admin, e.member, 1, authority.ModeStay, false))
	if err != nil || !res.Committed {
		t.Fatalf("handover: committed=%v err=%v", res.Committed, err)
	}
	if role, revoked := e.roleOf(t, e.member); role != "admin" || revoked {
		t.Fatalf("successor is %q revoked=%v", role, revoked)
	}
	if role, revoked := e.roleOf(t, e.admin); role != "member" || revoked {
		t.Fatalf("old admin is %q revoked=%v, want an active member", role, revoked)
	}
	if e.term(t) != 1 || e.required(t) {
		t.Fatalf("term=%d rotation owed=%v, want term 1 and no new key", e.term(t), e.required(t))
	}

	if err := e.repo.UpdateName(ctx, e.album, e.admin, []byte("x")); !errors.Is(err, repository.ErrNotAlbumAdmin) {
		t.Fatalf("old admin rename: %v, want ErrNotAlbumAdmin", err)
	}
	if _, err := e.repo.RevokeMemberTx(ctx, e.album, e.admin, third, repository.KeepMedia); !errors.Is(err, repository.ErrNotAlbumAdmin) {
		t.Fatalf("old admin kick: %v, want ErrNotAlbumAdmin", err)
	}
	if err := e.repo.UpdateName(ctx, e.album, e.member, []byte("x")); err != nil {
		t.Fatalf("new admin rename: %v", err)
	}
	if _, err := e.repo.RevokeMemberTx(ctx, e.album, e.member, third, repository.KeepMedia); err != nil {
		t.Fatalf("new admin kick: %v", err)
	}
}

func TestHandover_LeaveRevokesAndOwesARotationInOneStep(t *testing.T) {
	for _, deleteMedia := range []bool{false, true} {
		e := newHandoverEnv(t)
		ctx := context.Background()
		e.addPhoto(t, e.album, e.admin, false)

		res, err := e.repo.HandoverTx(ctx, e.request(t, e.admin, e.member, 1, authority.ModeLeave, deleteMedia))
		if err != nil {
			t.Fatalf("delete=%v: %v", deleteMedia, err)
		}
		// The cleanup queue is shared by every test in the package
		e.exec(`DELETE FROM media_object_cleanup WHERE storage_key = ANY($1)`, res.Media.Keys)
		if role, revoked := e.roleOf(t, e.admin); role != "member" || !revoked {
			t.Fatalf("old admin is %q revoked=%v, want a revoked member", role, revoked)
		}
		if role, _ := e.roleOf(t, e.member); role != "admin" {
			t.Fatalf("successor is %q", role)
		}
		if !e.required(t) {
			t.Fatal("leaving must owe a rotation, the old admin still holds the key")
		}
		var photos int
		if err := e.pool.QueryRow(ctx,
			`SELECT count(*) FROM media WHERE album_id = $1`, e.album).Scan(&photos); err != nil {
			t.Fatal(err)
		}
		if want := map[bool]int{false: 1, true: 0}[deleteMedia]; photos != want || (len(res.Media.MediaIDs) == 1) != deleteMedia {
			t.Fatalf("delete=%v left %d photos, removed %d", deleteMedia, photos, len(res.Media.MediaIDs))
		}
	}
}

func TestHandover_RefusesASuccessorWhoCannotTakeIt(t *testing.T) {
	cases := map[string]func(e *handoverEnv) []byte{
		"has not joined this membership": func(e *handoverEnv) []byte {
			e.exec(`UPDATE album_members SET acked_joins = 0 WHERE member_token = $1`, e.member)
			return e.member
		},
		"joined an earlier membership only": func(e *handoverEnv) []byte {
			e.exec(`UPDATE album_members SET joins = 2 WHERE member_token = $1`, e.member)
			return e.member
		},
		"holds no note": func(e *handoverEnv) []byte {
			e.exec(`DELETE FROM member_notes WHERE member_token = $1`, e.member)
			return e.member
		},
		"was removed": func(e *handoverEnv) []byte {
			e.exec(`UPDATE album_members SET revoked_at = now() WHERE member_token = $1`, e.member)
			return e.member
		},
		"is deleting their account": func(e *handoverEnv) []byte {
			e.exec(`UPDATE users SET deleting_at = now() WHERE id = $1`, e.joiner)
			return e.member
		},
		"is suspended": func(e *handoverEnv) []byte {
			e.exec(`UPDATE users SET suspended_at = now() WHERE id = $1`, e.joiner)
			return e.member
		},
		"is the admin themselves": func(e *handoverEnv) []byte { return e.admin },
		"is not in the album":     func(e *handoverEnv) []byte { return make([]byte, 32) },
	}
	for name, setup := range cases {
		t.Run(name, func(t *testing.T) {
			e := newHandoverEnv(t)
			to := setup(e)
			_, err := e.repo.HandoverTx(context.Background(), e.request(t, e.admin, to, 1, authority.ModeLeave, false))
			if !errors.Is(err, repository.ErrSuccessorIneligible) {
				t.Fatalf("err = %v, want ErrSuccessorIneligible", err)
			}
			if role, revoked := e.roleOf(t, e.admin); role != "admin" || revoked || e.term(t) != 0 {
				t.Fatal("a refused handover must change nothing")
			}
		})
	}
}

func TestHandover_RefusesWhatTheAdminDidNotSign(t *testing.T) {
	e := newHandoverEnv(t)
	ctx := context.Background()

	stale := e.request(t, e.admin, e.member, 2, authority.ModeStay, false)
	if _, err := e.repo.HandoverTx(ctx, stale); !errors.Is(err, repository.ErrStaleTerm) {
		t.Fatalf("wrong term: %v, want ErrStaleTerm", err)
	}

	flipped := e.request(t, e.admin, e.member, 1, authority.ModeStay, false)
	flipped.Mode = authority.ModeLeave
	if _, err := e.repo.HandoverTx(ctx, flipped); !errors.Is(err, repository.ErrHandoverSig) {
		t.Fatalf("mode changed after signing: %v, want ErrHandoverSig", err)
	}

	e.keys[string(e.member)] = e.keys[string(e.admin)]
	byMember := e.request(t, e.member, e.admin, 1, authority.ModeStay, false)
	if _, err := e.repo.HandoverTx(ctx, byMember); !errors.Is(err, repository.ErrNotAlbumAdmin) {
		t.Fatalf("a member handing over: %v, want ErrNotAlbumAdmin", err)
	}
	if e.term(t) != 0 {
		t.Fatal("no refused handover may advance the term")
	}
}

// The next handover signs the hash of the one before, so a record cannot be
// lifted out of the chain or replayed onto a later term
func TestHandover_ChainsToThePreviousRecord(t *testing.T) {
	e := newHandoverEnv(t)
	ctx := context.Background()
	e.giveKey(t, e.joiner, e.member)
	e.makeEligible(t, e.admin)

	unchained := e.request(t, e.member, e.admin, 2, authority.ModeStay, false)
	if _, err := e.repo.HandoverTx(ctx, e.request(t, e.admin, e.member, 1, authority.ModeStay, false)); err != nil {
		t.Fatal(err)
	}
	if _, err := e.repo.HandoverTx(ctx, unchained); !errors.Is(err, repository.ErrHandoverSig) {
		t.Fatalf("signed before the first handover existed: %v, want ErrHandoverSig", err)
	}
	if _, err := e.repo.HandoverTx(ctx, e.request(t, e.member, e.admin, 2, authority.ModeStay, false)); err != nil {
		t.Fatalf("chained handover back: %v", err)
	}
	if role, _ := e.roleOf(t, e.admin); role != "admin" || e.term(t) != 2 {
		t.Fatalf("role=%q term=%d, want the creator admin again at term 2", role, e.term(t))
	}
}

func TestHandover_RetryReturnsTheFirstResult(t *testing.T) {
	e := newHandoverEnv(t)
	ctx := context.Background()
	req := e.request(t, e.admin, e.member, 1, authority.ModeStay, false)

	if _, _, err := e.repo.HandoverOutcome(ctx, req.OperationID); !errors.Is(err, repository.ErrHandoverNotFound) {
		t.Fatalf("before commit: %v, want ErrHandoverNotFound", err)
	}
	if _, err := e.repo.HandoverTx(ctx, req); err != nil {
		t.Fatal(err)
	}
	again, err := e.repo.HandoverTx(ctx, req)
	if err != nil || again.Committed || again.Term != 1 || again.Mode != authority.ModeStay {
		t.Fatalf("retry: %+v err=%v, want the first result and no second commit", again, err)
	}
	if e.term(t) != 1 {
		t.Fatalf("term = %d after a retry, want 1", e.term(t))
	}

	other := req
	other.Mode, other.DeleteMedia = authority.ModeLeave, true
	if _, err := e.repo.HandoverTx(ctx, other); !errors.Is(err, repository.ErrHandoverReused) {
		t.Fatalf("same id, other content: %v, want ErrHandoverReused", err)
	}
	album, mode, err := e.repo.HandoverOutcome(ctx, req.OperationID)
	if err != nil || album != e.album || mode != authority.ModeStay {
		t.Fatalf("outcome = %v %d %v", album, mode, err)
	}
}

// Whichever commits first, the album never ends up led by a removed member
func TestHandover_RaceWithRemovingTheSuccessor(t *testing.T) {
	for i := range 25 {
		e := newHandoverEnv(t)
		ctx := context.Background()
		req := e.request(t, e.admin, e.member, 1, authority.ModeLeave, false)

		var handoverErr, kickErr error
		var wg sync.WaitGroup
		start := make(chan struct{})
		wg.Add(2)
		go func() {
			defer wg.Done()
			<-start
			_, handoverErr = e.repo.HandoverTx(ctx, req)
		}()
		go func() {
			defer wg.Done()
			<-start
			_, kickErr = e.repo.RevokeMemberTx(ctx, e.album, e.admin, e.member, repository.KeepMedia)
		}()
		close(start)
		wg.Wait()

		switch {
		case handoverErr == nil && kickErr == nil:
			t.Fatalf("round %d: the album was handed to a member removed in the same moment", i)
		case handoverErr == nil && !errors.Is(kickErr, repository.ErrCallerRevoked):
			t.Fatalf("round %d: kick after the handover: %v, want ErrCallerRevoked", i, kickErr)
		case kickErr == nil && !errors.Is(handoverErr, repository.ErrSuccessorIneligible):
			t.Fatalf("round %d: handover after the kick: %v, want ErrSuccessorIneligible", i, handoverErr)
		case handoverErr != nil && kickErr != nil:
			t.Fatalf("round %d: neither committed: %v, %v", i, handoverErr, kickErr)
		}
	}
}

func (e *handoverEnv) exec(sql string, args ...any) {
	if _, err := e.pool.Exec(context.Background(), sql, args...); err != nil {
		panic(err)
	}
}

func (e *handoverEnv) members(t *testing.T) []memberKeys {
	t.Helper()
	list, err := e.repo.ListMembers(context.Background(), e.album)
	if err != nil {
		t.Fatal(err)
	}
	out := make([]memberKeys, len(list))
	for i, m := range list {
		out[i].MemberToken = m.MemberToken
		out[i].Profile.IKPub, out[i].Profile.LKPub = m.Profile.IKPub, m.Profile.LKPub
	}
	return out
}

type memberKeys struct {
	MemberToken []byte
	Profile     struct{ IKPub, LKPub []byte }
}
