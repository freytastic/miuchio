package epoch

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/freytastic/miuchio/internal/e2ee/authority"
	"github.com/freytastic/miuchio/internal/middleware"
	"github.com/freytastic/miuchio/internal/repository"
	"github.com/freytastic/miuchio/internal/userlink"
	"github.com/freytastic/miuchio/internal/ws"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
	"github.com/jackc/pgx/v5/pgxpool"
)

// captureNotifier records every fanout for assertion. Buffer of 8 is enough
// for the heaviest test (race) where at most one set_epoch commits
type captureNotifier struct {
	ch chan emitted
}

type emitted struct {
	users []uuid.UUID
	typ   string
	data  any
}

func (c *captureNotifier) EmitToUsers(_ context.Context, ids []uuid.UUID, typ string, payload any) error {
	c.ch <- emitted{users: ids, typ: typ, data: payload}
	return nil
}

// testEnv seeds an album with an admin and two members behind the production
// RequireMember middleware
type testEnv struct {
	t         *testing.T
	pool      *pgxpool.Pool
	albumRepo *repository.AlbumRepository
	linker    *userlink.Hasher
	router    http.Handler
	notifier  *captureNotifier
	albumID   uuid.UUID
	users     map[string]testUser // role → user
}

type testUser struct {
	userID uuid.UUID
	token  []byte
	pub    ed25519.PublicKey
	priv   ed25519.PrivateKey
}

func mustOpenTestDB(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dbURL := os.Getenv("MIUCHIO_TEST_DATABASE_URL")
	if dbURL == "" {
		t.Skip("set MIUCHIO_TEST_DATABASE_URL to run real-DB epoch tests")
	}
	pool, err := pgxpool.New(context.Background(), dbURL)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)
	return pool
}

func newEnv(t *testing.T) *testEnv {
	t.Helper()
	pool := mustOpenTestDB(t)
	linker, err := userlink.New(bytes.Repeat([]byte{0x42}, 32))
	if err != nil {
		t.Fatalf("userlink: %v", err)
	}
	env := &testEnv{
		t:         t,
		pool:      pool,
		albumRepo: repository.NewAlbumRepository(pool, linker),
		linker:    linker,
		notifier:  &captureNotifier{ch: make(chan emitted, 8)},
		users:     make(map[string]testUser),
	}

	roles := []string{"admin", "peer", "member"}
	userIDs := make([]uuid.UUID, 0, 3)
	for _, role := range roles {
		u := seedUserWithIdentity(t, pool)
		env.users[role] = u
		userIDs = append(userIDs, u.userID)
	}
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM users WHERE id = ANY($1)`, userIDs)
	})

	ctx := context.Background()
	album, adminToken, err := env.albumRepo.CreateWithAdmin(ctx, []byte("test album"), env.users["admin"].userID)
	if err != nil {
		t.Fatalf("create album: %v", err)
	}
	env.albumID = album.ID
	env.users["admin"] = withToken(env.users["admin"], adminToken)

	for _, role := range []string{"peer", "member"} {
		u := env.users[role]
		token, err := env.albumRepo.AddMember(ctx, album.ID, u.userID, "member")
		if err != nil {
			t.Fatalf("add %s: %v", role, err)
		}
		env.users[role] = withToken(u, token)
	}

	repo := NewRepo(pool, env.linker)
	svc := NewService(repo)
	h := NewHandler(svc, repo, env.notifier)

	r := mux.NewRouter()
	scoped := r.PathPrefix("/api/v1/albums/{id}").Subrouter()
	scoped.Use(middleware.RequireMember(env.albumRepo, "id"))
	scoped.HandleFunc("/epoch", h.SetEpoch).Methods(http.MethodPost)
	scoped.HandleFunc("/epoch", h.GetCurrent).Methods(http.MethodGet)
	scoped.HandleFunc("/epoch/{n}/wrap", h.GetWrap).Methods(http.MethodGet)
	env.router = r

	return env
}

func withToken(u testUser, tok []byte) testUser {
	u.token = tok
	return u
}

// seedUserWithIdentity inserts a users row with a real Ed25519 IK_pub so the
// service's envelope_sig verify against caller IK works
func seedUserWithIdentity(t *testing.T, pool *pgxpool.Pool) testUser {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("ed25519: %v", err)
	}
	id := uuid.New()
	email := fmt.Sprintf("epoch-test-%s@example.com", id.String())
	lkPub := make([]byte, 32)
	spkPub := make([]byte, 32)
	spkSig := make([]byte, 64)
	spkTs := time.Now().Unix()
	if _, err := pool.Exec(context.Background(),
		`INSERT INTO users (id, email_hmac, miuchio_id, ik_pub, lk_pub, spk_pub, spk_sig, spk_ts)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
		id, []byte(email), id.String(), []byte(pub), lkPub, spkPub, spkSig, spkTs,
	); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	return testUser{userID: id, pub: pub, priv: priv}
}

// authReq builds an *http.Request whose ctx already has the user_id set, so
// middleware.RequireMember can resolve a member_token via album_member_identities
func authReq(method, path string, body []byte, userID uuid.UUID) *http.Request {
	var rdr *bytes.Reader
	if body != nil {
		rdr = bytes.NewReader(body)
	}
	var req *http.Request
	if rdr != nil {
		req = httptest.NewRequest(method, path, rdr)
	} else {
		req = httptest.NewRequest(method, path, nil)
	}
	ctx := context.WithValue(req.Context(), middleware.UserIDKey, userID)
	return req.WithContext(ctx)
}

// buildSetEpochBody composes a base64 encoded JSON body signed by 'signer'
// over canonical (album_id ‖ epoch ‖ member_set_hash ‖ wraps_hash) bytes
func buildSetEpochBody(t *testing.T, env *testEnv, signer testUser, epoch int, recipients ...testUser) []byte {
	t.Helper()
	wraps := make([]WrapInput, 0, len(recipients))
	itemsJSON := make([]map[string]any, 0, len(recipients))
	for _, rcpt := range recipients {
		nonce := bytes.Repeat([]byte{0x11}, gcmNonceLen)
		tagct := bytes.Repeat([]byte{0x22}, gcmTagLen+32)
		blob := append([]byte{verAesGcm}, nonce...)
		blob = append(blob, tagct...)
		ek := bytes.Repeat([]byte{0x33}, keyLen)
		ss := bytes.Repeat([]byte{0x44}, sigLen)
		wraps = append(wraps, WrapInput{
			RecipientToken: rcpt.token,
			EkPub:          ek,
			Wrap:           blob,
			SenderSig:      ss,
		})
		itemsJSON = append(itemsJSON, map[string]any{
			"recipient_token": base64.StdEncoding.EncodeToString(rcpt.token),
			"ek_pub":          base64.StdEncoding.EncodeToString(ek),
			"wrap":            base64.StdEncoding.EncodeToString(blob),
			"sender_sig":      base64.StdEncoding.EncodeToString(ss),
		})
	}
	tokens := make([][]byte, len(recipients))
	for i, r := range recipients {
		tokens[i] = r.token
	}
	memHash := MemberSetHash(tokens)
	wHash := WrapsHash(wraps)
	envSig := ed25519.Sign(signer.priv, EnvelopeSignMsg(env.albumID, epoch, memHash, wHash))

	req := map[string]any{
		"epoch":           epoch,
		"member_set_hash": base64.StdEncoding.EncodeToString(memHash),
		"wraps":           itemsJSON,
		"envelope_sig":    base64.StdEncoding.EncodeToString(envSig),
	}
	if epoch == 0 {
		req["signer_note"] = authority.NotesJSON([]authority.SignedNote{signNote(env, signer, signer, 1)})[0]
	}
	body, _ := json.Marshal(req)
	return body
}

func signNote(env *testEnv, issuer, member testUser, generation uint32) authority.SignedNote {
	note := authority.Note{
		AlbumID:     env.albumID,
		MemberToken: member.token,
		Generation:  generation,
		IKPub:       member.pub,
		LKPub:       make([]byte, 32),
	}
	return authority.SignedNote{Note: note, Sig: ed25519.Sign(issuer.priv, authority.NoteMsg(note))}
}

// Stands in for the invite, which is what stores a member's note
func (env *testEnv) giveNote(member testUser) {
	env.t.Helper()
	n := signNote(env, env.users["admin"], member, 1)
	if _, err := env.pool.Exec(context.Background(),
		`INSERT INTO member_notes (album_id, member_token, generation, issuer_term, ik_pub, lk_pub, sig)
		 VALUES ($1, $2, 1, 0, $3, $4, $5)`,
		env.albumID, n.MemberToken, n.IKPub, n.LKPub, n.Sig,
	); err != nil {
		env.t.Fatalf("seed note: %v", err)
	}
}

func (env *testEnv) setEpoch(caller testUser, body []byte) (int, string) {
	env.t.Helper()
	rec := httptest.NewRecorder()
	env.router.ServeHTTP(rec, authReq(http.MethodPost,
		"/api/v1/albums/"+env.albumID.String()+"/epoch", body, caller.userID))
	var resp struct{ Code string }
	_ = json.NewDecoder(rec.Body).Decode(&resp)
	return rec.Code, resp.Code
}

func (env *testEnv) revoke(member testUser) {
	env.t.Helper()
	if _, err := env.albumRepo.RevokeMemberTx(context.Background(), env.albumID,
		env.users["admin"].token, member.token, repository.KeepMedia); err != nil {
		env.t.Fatalf("revoke: %v", err)
	}
}

func TestSetEpoch_HappyPath(t *testing.T) {
	env := newEnv(t)
	body := buildSetEpochBody(t, env, env.users["admin"], 0,
		env.users["admin"], env.users["peer"], env.users["member"])

	rec := httptest.NewRecorder()
	req := authReq(http.MethodPost,
		"/api/v1/albums/"+env.albumID.String()+"/epoch", body, env.users["admin"].userID)
	env.router.ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201; body=%s", rec.Code, rec.Body.String())
	}
	var resp map[string]any
	_ = json.NewDecoder(rec.Body).Decode(&resp)
	if v, _ := resp["epoch"].(float64); v != 0 {
		t.Errorf("epoch = %v, want 0", resp["epoch"])
	}

	// fanout fires asynchronously
	select {
	case ev := <-env.notifier.ch:
		if ev.typ != ws.EventEpochChanged {
			t.Errorf("type = %q, want %q", ev.typ, ws.EventEpochChanged)
		}
		if len(ev.users) != 3 {
			t.Errorf("len(users) = %d, want 3", len(ev.users))
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for epoch_changed emit")
	}

	// GET /epoch reflects the new state
	rec2 := httptest.NewRecorder()
	req2 := authReq(http.MethodGet,
		"/api/v1/albums/"+env.albumID.String()+"/epoch", nil, env.users["admin"].userID)
	env.router.ServeHTTP(rec2, req2)
	if rec2.Code != http.StatusOK {
		t.Fatalf("GET status = %d, want 200", rec2.Code)
	}
	var cur map[string]any
	_ = json.NewDecoder(rec2.Body).Decode(&cur)
	if v, _ := cur["current_epoch"].(float64); v != 0 {
		t.Errorf("current_epoch = %v, want 0", cur["current_epoch"])
	}
	if _, ok := cur["join_acked"].(bool); !ok {
		t.Errorf("join_acked missing: %v", cur)
	}

	// each member can fetch their own wrap
	for _, role := range []string{"admin", "peer", "member"} {
		u := env.users[role]
		recW := httptest.NewRecorder()
		reqW := authReq(http.MethodGet,
			"/api/v1/albums/"+env.albumID.String()+"/epoch/0/wrap", nil, u.userID)
		env.router.ServeHTTP(recW, reqW)
		if recW.Code != http.StatusOK {
			t.Errorf("%s: wrap GET status = %d, want 200; body=%s", role, recW.Code, recW.Body.String())
		}
	}
}

func TestSetEpoch_ReplayRejected(t *testing.T) {
	env := newEnv(t)
	body := buildSetEpochBody(t, env, env.users["admin"], 0,
		env.users["admin"], env.users["peer"], env.users["member"])

	rec := httptest.NewRecorder()
	req := authReq(http.MethodPost,
		"/api/v1/albums/"+env.albumID.String()+"/epoch", body, env.users["admin"].userID)
	env.router.ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("first status = %d, want 201", rec.Code)
	}

	// drain the fanout to avoid blocking on the second post
	select {
	case <-env.notifier.ch:
	case <-time.After(2 * time.Second):
	}

	rec2 := httptest.NewRecorder()
	req2 := authReq(http.MethodPost,
		"/api/v1/albums/"+env.albumID.String()+"/epoch", body, env.users["admin"].userID)
	env.router.ServeHTTP(rec2, req2)
	if rec2.Code != http.StatusConflict {
		t.Fatalf("replay status = %d, want 409; body=%s", rec2.Code, rec2.Body.String())
	}
	var env2 struct{ Code string }
	_ = json.NewDecoder(rec2.Body).Decode(&env2)
	if env2.Code != "E_EPOCH_REPLAY" {
		t.Errorf("code = %q, want E_EPOCH_REPLAY", env2.Code)
	}
}

func TestSetEpoch_TamperedEnvelopeSig(t *testing.T) {
	env := newEnv(t)
	body := buildSetEpochBody(t, env, env.users["admin"], 0,
		env.users["admin"], env.users["peer"], env.users["member"])

	// flip a bit inside envelope_sig (the JSON body is a map, so we re decode + re encode)
	var raw map[string]any
	_ = json.Unmarshal(body, &raw)
	sigStr, _ := raw["envelope_sig"].(string)
	sigBytes, _ := base64.StdEncoding.DecodeString(sigStr)
	sigBytes[0] ^= 0x01
	raw["envelope_sig"] = base64.StdEncoding.EncodeToString(sigBytes)
	tampered, _ := json.Marshal(raw)

	rec := httptest.NewRecorder()
	req := authReq(http.MethodPost,
		"/api/v1/albums/"+env.albumID.String()+"/epoch", tampered, env.users["admin"].userID)
	env.router.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body=%s", rec.Code, rec.Body.String())
	}
	var resp struct{ Code string }
	_ = json.NewDecoder(rec.Body).Decode(&resp)
	if resp.Code != "E_SIG_INVALID" {
		t.Errorf("code = %q, want E_SIG_INVALID", resp.Code)
	}
}

func TestSetEpoch_FirstEpochIsTheCreatorsAlone(t *testing.T) {
	env := newEnv(t)
	body := buildSetEpochBody(t, env, env.users["member"], 0,
		env.users["admin"], env.users["peer"], env.users["member"])

	if status, code := env.setEpoch(env.users["member"], body); status != http.StatusForbidden || code != "E_FORBIDDEN" {
		t.Fatalf("got %d %s, want 403 E_FORBIDDEN", status, code)
	}
}

func TestSetEpoch_MemberRotatesOnlyWhatIsOwed(t *testing.T) {
	env := newEnv(t)
	admin, peer, member := env.users["admin"], env.users["peer"], env.users["member"]
	if status, code := env.setEpoch(admin, buildSetEpochBody(t, env, admin, 0, admin, peer, member)); status != http.StatusCreated {
		t.Fatalf("epoch 0: %d %s", status, code)
	}
	env.giveNote(member)

	if status, code := env.setEpoch(member, buildSetEpochBody(t, env, member, 1, admin, peer, member)); status != http.StatusForbidden || code != "E_FORBIDDEN" {
		t.Fatalf("nothing owed: got %d %s, want 403 E_FORBIDDEN", status, code)
	}

	env.revoke(peer)
	if status, code := env.setEpoch(member, buildSetEpochBody(t, env, member, 1, admin, member)); status != http.StatusCreated {
		t.Fatalf("owed rotation by a member: %d %s", status, code)
	}

	var sender []byte
	var generation int
	if err := env.pool.QueryRow(context.Background(),
		`SELECT sender_token, sender_generation FROM album_epoch_wraps
		 WHERE album_id = $1 AND epoch = 1 AND recipient_token = $2`,
		env.albumID, admin.token,
	).Scan(&sender, &generation); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(sender, member.token) || generation != 1 {
		t.Fatalf("wrap sender = %x generation %d, want the member at generation 1", sender, generation)
	}

	rec := httptest.NewRecorder()
	env.router.ServeHTTP(rec, authReq(http.MethodGet,
		"/api/v1/albums/"+env.albumID.String()+"/epoch/1/wrap", nil, admin.userID))
	var wrap struct {
		SenderGeneration int                  `json:"sender_generation"`
		SenderNotes      []authority.NoteJSON `json:"sender_notes"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&wrap); err != nil {
		t.Fatal(err)
	}
	if wrap.SenderGeneration != 1 || len(wrap.SenderNotes) != 1 ||
		wrap.SenderNotes[0].IKPub != base64.StdEncoding.EncodeToString(member.pub) {
		t.Fatalf("wrap did not carry the member's note: %+v", wrap)
	}
}

func TestSetEpoch_MemberWithoutNoteCannotRotate(t *testing.T) {
	env := newEnv(t)
	admin, peer, member := env.users["admin"], env.users["peer"], env.users["member"]
	if status, code := env.setEpoch(admin, buildSetEpochBody(t, env, admin, 0, admin, peer, member)); status != http.StatusCreated {
		t.Fatalf("epoch 0: %d %s", status, code)
	}
	env.revoke(peer)

	if status, code := env.setEpoch(member, buildSetEpochBody(t, env, member, 1, admin, member)); status != http.StatusForbidden || code != "E_FORBIDDEN" {
		t.Fatalf("got %d %s, want 403 E_FORBIDDEN", status, code)
	}
}

// A member removed while its rotation is in flight must not mint the key
func TestSetEpoch_RevokedMemberCannotRotate(t *testing.T) {
	env := newEnv(t)
	admin, peer, member := env.users["admin"], env.users["peer"], env.users["member"]
	if status, code := env.setEpoch(admin, buildSetEpochBody(t, env, admin, 0, admin, peer, member)); status != http.StatusCreated {
		t.Fatalf("epoch 0: %d %s", status, code)
	}
	env.giveNote(member)
	env.revoke(peer)
	body := buildSetEpochBody(t, env, member, 1, admin, member)
	env.revoke(member)

	in := InsertEpochInput{AlbumID: env.albumID, Epoch: 1, SenderToken: member.token}
	if err := NewRepo(env.pool, env.linker).InsertEpoch(context.Background(), in); !errors.Is(err, ErrCallerRevoked) {
		t.Fatalf("err = %v, want ErrCallerRevoked", err)
	}
	if status, _ := env.setEpoch(member, body); status != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", status)
	}
}

// Members racing to settle the same debt: one key, the rest told to catch up
func TestSetEpoch_MembersRaceForOneOwedRotation(t *testing.T) {
	env := newEnv(t)
	admin, peer, member := env.users["admin"], env.users["peer"], env.users["member"]
	if status, code := env.setEpoch(admin, buildSetEpochBody(t, env, admin, 0, admin, peer, member)); status != http.StatusCreated {
		t.Fatalf("epoch 0: %d %s", status, code)
	}
	env.giveNote(peer)
	env.giveNote(member)
	if _, err := env.pool.Exec(context.Background(),
		`UPDATE albums SET rotation_required = TRUE WHERE id = $1`, env.albumID); err != nil {
		t.Fatal(err)
	}

	racers := []testUser{peer, member, admin}
	statuses := make([]int, len(racers))
	codes := make([]string, len(racers))
	var wg sync.WaitGroup
	start := make(chan struct{})
	for i, u := range racers {
		body := buildSetEpochBody(t, env, u, 1, admin, peer, member)
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			statuses[i], codes[i] = env.setEpoch(u, body)
		}()
	}
	close(start)
	wg.Wait()

	won := 0
	for i := range racers {
		switch {
		case statuses[i] == http.StatusCreated:
			won++
		case codes[i] != "E_EPOCH_REPLAY" && codes[i] != "E_FORBIDDEN":
			t.Errorf("loser got %d %s", statuses[i], codes[i])
		}
	}
	if won != 1 {
		t.Fatalf("winners = %d, want exactly 1", won)
	}
}

func TestSetEpoch_Race(t *testing.T) {
	env := newEnv(t)

	const N = 4
	var wg sync.WaitGroup
	successes := atomic.Int32{}
	codes := make(chan string, N)

	bodies := make([][]byte, N)
	for i := range bodies {
		bodies[i] = buildSetEpochBody(t, env, env.users["admin"], 0,
			env.users["admin"], env.users["peer"], env.users["member"])
	}

	start := make(chan struct{})

	for i := range N {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			caller := env.users["admin"]
			rec := httptest.NewRecorder()
			req := authReq(
				http.MethodPost,
				"/api/v1/albums/"+env.albumID.String()+"/epoch",
				bodies[i],
				caller.userID,
			)
			env.router.ServeHTTP(rec, req)

			if rec.Code == http.StatusCreated {
				successes.Add(1)
				codes <- "OK"
				return
			}
			var resp struct{ Code string }
			_ = json.NewDecoder(rec.Body).Decode(&resp)
			codes <- resp.Code
		}(i)
	}

	close(start)
	wg.Wait()
	close(codes)

	if got := successes.Load(); got != 1 {
		t.Fatalf("successes = %d, want exactly 1", got)
	}
	losers := 0
	for code := range codes {
		if code != "OK" {
			losers++
			if code != "E_EPOCH_REPLAY" {
				t.Errorf("loser got code %q, want E_EPOCH_REPLAY", code)
			}
		}
	}
	if losers != N-1 {
		t.Errorf("losers = %d, want %d", losers, N-1)
	}
}

func TestSetEpoch_MemberSetDrift(t *testing.T) {
	env := newEnv(t)
	// build the body listing only admin + co-admin (NOT the member)
	// the live snapshot has all 3 → drift
	body := buildSetEpochBody(t, env, env.users["admin"], 0,
		env.users["admin"], env.users["peer"])

	rec := httptest.NewRecorder()
	req := authReq(http.MethodPost,
		"/api/v1/albums/"+env.albumID.String()+"/epoch", body, env.users["admin"].userID)
	env.router.ServeHTTP(rec, req)

	if rec.Code != http.StatusConflict {
		t.Fatalf("status = %d, want 409; body=%s", rec.Code, rec.Body.String())
	}
	var resp struct{ Code string }
	_ = json.NewDecoder(rec.Body).Decode(&resp)
	if resp.Code != "E_MEMBER_SET_DRIFT" {
		t.Errorf("code = %q, want E_MEMBER_SET_DRIFT", resp.Code)
	}
}

func TestGetEpoch_NoEpochsYet(t *testing.T) {
	env := newEnv(t)
	rec := httptest.NewRecorder()
	req := authReq(http.MethodGet,
		"/api/v1/albums/"+env.albumID.String()+"/epoch", nil, env.users["admin"].userID)
	env.router.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
}

func TestGetWrap_OnlyOwnerSucceeds(t *testing.T) {
	env := newEnv(t)
	body := buildSetEpochBody(t, env, env.users["admin"], 0,
		env.users["admin"], env.users["peer"], env.users["member"])
	rec := httptest.NewRecorder()
	req := authReq(http.MethodPost,
		"/api/v1/albums/"+env.albumID.String()+"/epoch", body, env.users["admin"].userID)
	env.router.ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("set_epoch status = %d, want 201; body=%s", rec.Code, rec.Body.String())
	}
	// drain fanout
	select {
	case <-env.notifier.ch:
	case <-time.After(2 * time.Second):
	}

	// each user gets their own wrap
	for _, role := range []string{"admin", "peer", "member"} {
		u := env.users[role]
		recW := httptest.NewRecorder()
		reqW := authReq(http.MethodGet,
			"/api/v1/albums/"+env.albumID.String()+"/epoch/0/wrap", nil, u.userID)
		env.router.ServeHTTP(recW, reqW)
		if recW.Code != http.StatusOK {
			t.Errorf("%s: status = %d, want 200; body=%s", role, recW.Code, recW.Body.String())
			continue
		}
		var resp struct {
			Epoch       int    `json:"epoch"`
			SenderToken string `json:"sender_token"`
		}
		_ = json.NewDecoder(recW.Body).Decode(&resp)
		if resp.Epoch != 0 {
			t.Errorf("%s: epoch = %d, want 0", role, resp.Epoch)
		}
		// sender_token must equal the rotater (admin)
		got, _ := base64.StdEncoding.DecodeString(resp.SenderToken)
		if !bytes.Equal(got, env.users["admin"].token) {
			t.Errorf("%s: sender_token mismatch", role)
		}
	}
}
