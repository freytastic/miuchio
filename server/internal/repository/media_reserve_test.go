package repository_test

import (
	"bytes"
	"context"
	"errors"
	"testing"

	"github.com/freytastic/miuchio/internal/model"
	"github.com/freytastic/miuchio/internal/repository"
	"github.com/google/uuid"
)

// Uses the real repository because retry behavior is transactional SQL
func reserveEnv(t *testing.T) (*summaryEnv, uuid.UUID, []byte) {
	t.Helper()
	env := newSummaryEnv(t)
	ctx := context.Background()
	owner := env.seedUser(t)
	album, token, err := env.repo.CreateWithAdmin(ctx, []byte("reserve"), owner)
	if err != nil {
		t.Fatalf("create album: %v", err)
	}
	t.Cleanup(func() {
		// Remove shared cleanup rows from replaced reservations
		_, _ = env.pool.Exec(ctx,
			`DELETE FROM media_object_cleanup
			 WHERE storage_key LIKE 'key-%' OR storage_key LIKE 'thumb-%'`)
		_, _ = env.pool.Exec(ctx, `DELETE FROM albums WHERE id = $1`, album.ID)
	})
	seedUploadable(t, env, album.ID, token)
	return env, album.ID, token
}

func seedUploadable(t *testing.T, env *summaryEnv, albumID uuid.UUID, token []byte) {
	t.Helper()
	ctx := context.Background()
	if _, err := env.pool.Exec(ctx,
		`INSERT INTO album_epochs (album_id, epoch) VALUES ($1, 0)`, albumID,
	); err != nil {
		t.Fatalf("seed epoch: %v", err)
	}
	// A complete epoch wrap is required before uploads are allowed
	if _, err := env.pool.Exec(ctx,
		`INSERT INTO album_epoch_wraps
		   (album_id, epoch, recipient_token, ek_pub, wrap_nonce, wrap_tag_ct,
		    sender_token, sender_sig)
		 VALUES ($1, 0, $2, $3, $4, $5, $2, $6)`,
		albumID, token, make([]byte, 32), make([]byte, 12), make([]byte, 48),
		make([]byte, 64),
	); err != nil {
		t.Fatalf("seed wrap: %v", err)
	}
}

func pendingRow(albumID, mediaID uuid.UUID, token []byte, storageKey, thumbKey string) *model.Media {
	thumb := thumbKey
	size := int64(64)
	return &model.Media{
		ID:             mediaID,
		AlbumID:        albumID,
		UploaderToken:  token,
		StorageKey:     storageKey,
		ThumbKey:       &thumb,
		WrapNonce:      make([]byte, 12),
		WrapTagCT:      make([]byte, 48),
		EpochTag:       0,
		BlobSize:       4096,
		BlobSHA256:     make([]byte, 32),
		MediaType:      "photo",
		ThumbWrapNonce: make([]byte, 12),
		ThumbWrapTagCT: make([]byte, 48),
		ThumbSize:      &size,
		ThumbSHA256:    make([]byte, 32),
	}
}

func TestReserveUploadRow_RetryDoesNotCollide(t *testing.T) {
	env, albumID, token := reserveEnv(t)
	ctx := context.Background()
	mediaID := uuid.New()

	first := pendingRow(albumID, mediaID, token, "key-one", "thumb-one")
	if err := env.media.ReserveUploadRow(ctx, first, 0); err != nil {
		t.Fatalf("first reserve: %v", err)
	}

	second := pendingRow(albumID, mediaID, token, "key-two", "thumb-two")
	if err := env.media.ReserveUploadRow(ctx, second, 0); err != nil {
		t.Fatalf("retry reserve must not hit the primary key, got: %v", err)
	}

	row, err := env.media.GetByID(ctx, mediaID, albumID)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if row.Confirmed {
		t.Error("the replacement row must still be pending")
	}
	if row.StorageKey != second.StorageKey {
		t.Errorf("row key = %q, reservation reported %q",
			row.StorageKey, second.StorageKey)
	}
}

// A thumbnail retry must keep the key of an already uploaded file
func TestReserveUploadRow_RePresignKeepsKeysWhenBytesAreIdentical(t *testing.T) {
	env, albumID, token := reserveEnv(t)
	ctx := context.Background()
	mediaID := uuid.New()

	first := pendingRow(albumID, mediaID, token, "key-stable", "thumb-stable")
	if err := env.media.ReserveUploadRow(ctx, first, 0); err != nil {
		t.Fatalf("first reserve: %v", err)
	}

	second := pendingRow(albumID, mediaID, token, "key-fresh", "thumb-fresh")
	if err := env.media.ReserveUploadRow(ctx, second, 0); err != nil {
		t.Fatalf("re presign: %v", err)
	}
	if second.StorageKey != "key-stable" {
		t.Errorf("storage_key = %q, want the original key kept", second.StorageKey)
	}
	if second.ThumbKey == nil || *second.ThumbKey != "thumb-stable" {
		t.Errorf("thumb_key = %v, want the original thumb key kept", second.ThumbKey)
	}

	keys, err := env.media.ListObjectCleanupKeys(ctx, 10)
	if err != nil {
		t.Fatalf("cleanup keys: %v", err)
	}
	for _, k := range keys {
		if k == "key-stable" || k == "thumb-stable" {
			t.Errorf("%q is still live and must not be queued for deletion", k)
		}
	}
}

func TestReserveUploadRow_NewBytesGetNewKeys(t *testing.T) {
	env, albumID, token := reserveEnv(t)
	ctx := context.Background()
	mediaID := uuid.New()

	first := pendingRow(albumID, mediaID, token, "key-old", "thumb-old")
	if err := env.media.ReserveUploadRow(ctx, first, 0); err != nil {
		t.Fatalf("first reserve: %v", err)
	}

	second := pendingRow(albumID, mediaID, token, "key-new", "thumb-new")
	second.BlobSHA256 = bytes.Repeat([]byte{0x9}, 32)
	if err := env.media.ReserveUploadRow(ctx, second, 0); err != nil {
		t.Fatalf("re reserve: %v", err)
	}
	if second.StorageKey != "key-new" {
		t.Errorf("storage_key = %q, want a fresh key", second.StorageKey)
	}

	keys, err := env.media.ListObjectCleanupKeys(ctx, 20)
	if err != nil {
		t.Fatalf("cleanup keys: %v", err)
	}
	found := false
	for _, k := range keys {
		if k == "key-old" {
			found = true
		}
	}
	if !found {
		t.Errorf("the superseded object was not queued for cleanup, got %v", keys)
	}
	t.Cleanup(func() {
		_, _ = env.pool.Exec(ctx, `DELETE FROM media_object_cleanup`)
	})
}

func TestReserveUploadRow_RefusesReplayOfConfirmedMedia(t *testing.T) {
	env, albumID, token := reserveEnv(t)
	ctx := context.Background()
	mediaID := uuid.New()

	row := pendingRow(albumID, mediaID, token, "key-confirmed", "thumb-confirmed")
	if err := env.media.ReserveUploadRow(ctx, row, 0); err != nil {
		t.Fatalf("reserve: %v", err)
	}
	if _, err := env.media.MarkConfirmed(ctx, mediaID, albumID, row.ReservationID); err != nil {
		t.Fatalf("confirm: %v", err)
	}

	again := pendingRow(albumID, mediaID, token, "key-replay", "thumb-replay")
	err := env.media.ReserveUploadRow(ctx, again, 0)
	if !errors.Is(err, repository.ErrMediaConfirmed) {
		t.Fatalf("err = %v, want ErrMediaConfirmed", err)
	}
}

func TestReserveUploadRow_RefusesAnotherUploadersReservation(t *testing.T) {
	env, albumID, token := reserveEnv(t)
	ctx := context.Background()
	mediaID := uuid.New()

	mine := pendingRow(albumID, mediaID, token, "key-mine", "thumb-mine")
	if err := env.media.ReserveUploadRow(ctx, mine, 0); err != nil {
		t.Fatalf("reserve: %v", err)
	}

	theirs := pendingRow(albumID, mediaID, []byte("someone-else-token"), "key-theirs", "thumb-theirs")
	err := env.media.ReserveUploadRow(ctx, theirs, 0)
	if !errors.Is(err, repository.ErrMediaNotOwned) {
		t.Fatalf("err = %v, want ErrMediaNotOwned", err)
	}

	row, getErr := env.media.GetByID(ctx, mediaID, albumID)
	if getErr != nil {
		t.Fatalf("get: %v", getErr)
	}
	if row.StorageKey != "key-mine" {
		t.Errorf("storage_key = %q, the original reservation must survive", row.StorageKey)
	}
}

func TestMarkConfirmed_RefusesAReplacedReservation(t *testing.T) {
	env, albumID, token := reserveEnv(t)
	ctx := context.Background()
	mediaID := uuid.New()

	first := pendingRow(albumID, mediaID, token, "key-a", "thumb-a")
	if err := env.media.ReserveUploadRow(ctx, first, 0); err != nil {
		t.Fatalf("first reserve: %v", err)
	}

	second := pendingRow(albumID, mediaID, token, "key-b", "thumb-b")
	second.BlobSHA256 = bytes.Repeat([]byte{0x9}, 32)
	if err := env.media.ReserveUploadRow(ctx, second, 0); err != nil {
		t.Fatalf("second reserve: %v", err)
	}

	_, err := env.media.MarkConfirmed(ctx, mediaID, albumID, first.ReservationID)
	if !errors.Is(err, repository.ErrMediaNotFound) {
		t.Fatalf("stale confirm err = %v, want ErrMediaNotFound", err)
	}

	var confirmed bool
	if err := env.pool.QueryRow(ctx,
		`SELECT confirmed FROM media WHERE id = $1`, mediaID).Scan(&confirmed); err != nil {
		t.Fatalf("read row: %v", err)
	}
	if confirmed {
		t.Fatal("a confirm for objects that are no longer this row's committed it")
	}
}

func TestQueuePendingCleanup_LeavesANewerReservationAlone(t *testing.T) {
	env, albumID, token := reserveEnv(t)
	ctx := context.Background()
	mediaID := uuid.New()

	first := pendingRow(albumID, mediaID, token, "key-a", "thumb-a")
	if err := env.media.ReserveUploadRow(ctx, first, 0); err != nil {
		t.Fatalf("first reserve: %v", err)
	}
	second := pendingRow(albumID, mediaID, token, "key-b", "thumb-b")
	second.BlobSHA256 = bytes.Repeat([]byte{0x9}, 32)
	if err := env.media.ReserveUploadRow(ctx, second, 0); err != nil {
		t.Fatalf("second reserve: %v", err)
	}

	batch, err := env.media.QueuePendingCleanup(ctx, mediaID, albumID, token, first.ReservationID)
	if err != nil {
		t.Fatalf("cleanup: %v", err)
	}
	if batch.MediaCount != 0 {
		t.Fatalf("retired %d rows, want 0", batch.MediaCount)
	}

	var live string
	if err := env.pool.QueryRow(ctx,
		`SELECT storage_key FROM media WHERE id = $1`, mediaID).Scan(&live); err != nil {
		t.Fatalf("newer reservation was deleted by a stale cleanup: %v", err)
	}
	if live != "key-b" {
		t.Fatalf("storage key = %q, want key-b", live)
	}
}

func TestQueuePendingCleanup_LeavesAnIdenticalReReservationAlone(t *testing.T) {
	env, albumID, token := reserveEnv(t)
	ctx := context.Background()
	mediaID := uuid.New()

	first := pendingRow(albumID, mediaID, token, "key-a", "thumb-a")
	if err := env.media.ReserveUploadRow(ctx, first, 0); err != nil {
		t.Fatalf("first reserve: %v", err)
	}
	staleReservation := first.ReservationID

	second := pendingRow(albumID, mediaID, token, "key-ignored", "thumb-ignored")
	if err := env.media.ReserveUploadRow(ctx, second, 0); err != nil {
		t.Fatalf("second reserve: %v", err)
	}
	if second.StorageKey != first.StorageKey {
		t.Fatalf("expected the key to be retained, got %q", second.StorageKey)
	}
	if second.ReservationID == staleReservation {
		t.Fatal("a replacement reservation reused the previous reservation id")
	}

	batch, err := env.media.QueuePendingCleanup(ctx, mediaID, albumID, token, staleReservation)
	if err != nil {
		t.Fatalf("cleanup: %v", err)
	}
	if batch.MediaCount != 0 {
		t.Fatalf("a stale cleanup retired %d rows, want 0", batch.MediaCount)
	}
	if _, err := env.media.GetByID(ctx, mediaID, albumID); err != nil {
		t.Fatalf("the live reservation was deleted: %v", err)
	}
}

func TestMarkConfirmed_RefusesAnIdenticalReReservation(t *testing.T) {
	env, albumID, token := reserveEnv(t)
	ctx := context.Background()
	mediaID := uuid.New()

	first := pendingRow(albumID, mediaID, token, "key-a", "thumb-a")
	if err := env.media.ReserveUploadRow(ctx, first, 0); err != nil {
		t.Fatalf("first reserve: %v", err)
	}
	staleReservation := first.ReservationID

	second := pendingRow(albumID, mediaID, token, "key-ignored", "thumb-ignored")
	if err := env.media.ReserveUploadRow(ctx, second, 0); err != nil {
		t.Fatalf("second reserve: %v", err)
	}

	if _, err := env.media.MarkConfirmed(ctx, mediaID, albumID, staleReservation); !errors.Is(err, repository.ErrMediaNotFound) {
		t.Fatalf("stale confirm err = %v, want ErrMediaNotFound", err)
	}
	if _, err := env.media.MarkConfirmed(ctx, mediaID, albumID, second.ReservationID); err != nil {
		t.Fatalf("current confirm: %v", err)
	}
}

// A retry replaces its own pending row, so it must not count twice
func TestReserveUploadRow_EnforcesAccountQuota(t *testing.T) {
	env, albumID, token := reserveEnv(t)
	ctx := context.Background()
	perRow := int64(4096 + 64)
	media := repository.NewMediaRepository(env.pool, repository.StorageQuota{PerUser: 2 * perRow})

	firstID := uuid.New()
	if err := media.ReserveUploadRow(ctx, pendingRow(albumID, firstID, token, "key-q1", "thumb-q1"), 0); err != nil {
		t.Fatalf("first reserve: %v", err)
	}
	if err := media.ReserveUploadRow(ctx, pendingRow(albumID, firstID, token, "key-q1b", "thumb-q1b"), 0); err != nil {
		t.Fatalf("retry reserve: %v", err)
	}
	if err := media.ReserveUploadRow(ctx, pendingRow(albumID, uuid.New(), token, "key-q2", "thumb-q2"), 0); err != nil {
		t.Fatalf("second reserve fills the quota exactly: %v", err)
	}
	err := media.ReserveUploadRow(ctx, pendingRow(albumID, uuid.New(), token, "key-q3", "thumb-q3"), 0)
	if !errors.Is(err, repository.ErrQuotaExceeded) {
		t.Fatalf("third reserve err = %v, want ErrQuotaExceeded", err)
	}
}

// Photos kept in an album the uploader left stay on their quota, otherwise
// leaving would free space while the bytes stay stored
func TestReserveUploadRow_KeptPhotosStillCount(t *testing.T) {
	env := newSummaryEnv(t)
	ctx := context.Background()
	owner, joiner := env.seedUser(t), env.seedUser(t)
	shared, _, err := env.repo.CreateWithAdmin(ctx, []byte("shared"), owner)
	if err != nil {
		t.Fatalf("create shared album: %v", err)
	}
	own, ownToken, err := env.repo.CreateWithAdmin(ctx, []byte("own"), joiner)
	if err != nil {
		t.Fatalf("create own album: %v", err)
	}
	t.Cleanup(func() {
		_, _ = env.pool.Exec(ctx, `DELETE FROM albums WHERE id = ANY($1)`, []uuid.UUID{shared.ID, own.ID})
	})
	member, err := env.repo.AddMember(ctx, shared.ID, joiner, "member")
	if err != nil {
		t.Fatalf("add member: %v", err)
	}
	kept := int64(1000)
	if _, err := env.pool.Exec(ctx,
		`INSERT INTO media (id, album_id, uploader_token, storage_key,
		   wrap_nonce, wrap_tag_ct, epoch_tag, blob_size, blob_sha256, media_type, confirmed)
		 VALUES ($1, $2, $3, $4, $5, $6, 0, $7, $8, 'photo', TRUE)`,
		uuid.New(), shared.ID, member, "key-kept", make([]byte, 12), make([]byte, 48),
		kept, make([]byte, 32),
	); err != nil {
		t.Fatalf("insert photo: %v", err)
	}
	if _, err := env.repo.RevokeMemberTx(ctx, shared.ID, member, member, repository.KeepMedia); err != nil {
		t.Fatalf("leave: %v", err)
	}

	seedUploadable(t, env, own.ID, ownToken)
	perRow := int64(4096 + 64)
	media := repository.NewMediaRepository(env.pool, repository.StorageQuota{PerUser: perRow + kept - 1})
	err = media.ReserveUploadRow(ctx, pendingRow(own.ID, uuid.New(), ownToken, "key-own", "thumb-own"), 0)
	if !errors.Is(err, repository.ErrQuotaExceeded) {
		t.Fatalf("reserve err = %v, want ErrQuotaExceeded from the kept photo", err)
	}
}
