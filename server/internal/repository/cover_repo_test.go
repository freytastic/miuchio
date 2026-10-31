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

func coverUpload(e *avatarEnv, key string) *model.AlbumCover {
	return &model.AlbumCover{
		CoverID:    uuid.New(),
		AlbumID:    e.album,
		SetBy:      e.admin,
		StorageKey: key,
		BlobSize:   393245,
		BlobSHA256: bytes.Repeat([]byte{key[len(key)-1]}, 32),
		KeyCT:      make([]byte, 65),
	}
}

func listedCover(t *testing.T, e *avatarEnv) (*model.CoverRef, []model.PreviewMedia) {
	t.Helper()
	albums, err := e.repo.ListForUser(context.Background(), e.pal)
	if err != nil {
		t.Fatalf("list albums: %v", err)
	}
	for _, a := range albums {
		if a.ID == e.album {
			return a.Cover, a.Summary.PreviewMedia
		}
	}
	t.Fatalf("album missing from listing")
	return nil, nil
}

func TestCover_OnlyTheOwnerAndEachChoiceRetiresTheLast(t *testing.T) {
	e := newAvatarEnv(t)
	covers := repository.NewCoverRepository(e.pool, repository.StorageQuota{})
	ctx := context.Background()
	t.Cleanup(func() {
		_, _ = e.pool.Exec(ctx, `DELETE FROM media_object_cleanup WHERE storage_key LIKE 'cover-%'`)
	})

	byMember := coverUpload(e, "cover-m")
	byMember.SetBy = e.friend
	if err := covers.Reserve(ctx, byMember); !errors.Is(err, repository.ErrNotAlbumAdmin) {
		t.Fatalf("member reserve = %v, want ErrNotAlbumAdmin", err)
	}

	up := coverUpload(e, "cover-a")
	if err := covers.Reserve(ctx, up); err != nil {
		t.Fatalf("reserve: %v", err)
	}
	if got, _ := listedCover(t, e); got != nil {
		t.Fatalf("pending cover leaked into the listing: %+v", got)
	}
	if _, err := covers.Confirm(ctx, e.album, e.admin, up.CoverID, up.StorageKey); err != nil {
		t.Fatalf("confirm: %v", err)
	}
	got, _ := listedCover(t, e)
	if got == nil || got.CoverID != up.CoverID || got.MediaID != nil ||
		!bytes.Equal(got.SetBy, e.admin) || !bytes.Equal(got.KeyCT, up.KeyCT) {
		t.Fatalf("listed cover = %+v, want the confirmed upload", got)
	}

	older, _ := e.addPhotoID(t, e.album, e.admin, true)
	e.addPhoto(t, e.album, e.admin, true)
	if _, err := covers.SetMedia(ctx, e.album, e.friend, &older); !errors.Is(err, repository.ErrNotAlbumAdmin) {
		t.Fatalf("member set = %v, want ErrNotAlbumAdmin", err)
	}
	if _, err := covers.SetMedia(ctx, e.album, e.admin, &older); err != nil {
		t.Fatalf("set media: %v", err)
	}
	if !e.queued(t, "cover-a") {
		t.Fatalf("the replaced upload was not queued for cleanup")
	}
	got, previews := listedCover(t, e)
	if got == nil || got.MediaID == nil || *got.MediaID != older {
		t.Fatalf("listed cover = %+v, want the chosen photo", got)
	}
	if len(previews) == 0 || previews[0].MediaID != older {
		t.Fatalf("previews do not lead with the chosen photo")
	}

	if _, err := covers.SetMedia(ctx, e.album, e.admin, nil); err != nil {
		t.Fatalf("clear: %v", err)
	}
	if got, _ := listedCover(t, e); got != nil {
		t.Fatalf("cleared cover still listed: %+v", got)
	}
}

func TestCover_AlbumDeleteQueuesTheUpload(t *testing.T) {
	e := newAvatarEnv(t)
	covers := repository.NewCoverRepository(e.pool, repository.StorageQuota{})
	ctx := context.Background()
	t.Cleanup(func() {
		_, _ = e.pool.Exec(ctx, `DELETE FROM media_object_cleanup WHERE storage_key LIKE 'cover-%'`)
	})

	up := coverUpload(e, "cover-d")
	if err := covers.Reserve(ctx, up); err != nil {
		t.Fatalf("reserve: %v", err)
	}
	if _, err := covers.Confirm(ctx, e.album, e.admin, up.CoverID, up.StorageKey); err != nil {
		t.Fatalf("confirm: %v", err)
	}
	if _, err := e.repo.DeleteAlbumTx(ctx, e.album, e.admin); err != nil {
		t.Fatalf("delete album: %v", err)
	}
	if !e.queued(t, "cover-d") {
		t.Fatalf("deleting the album orphaned its uploaded cover")
	}
}

// Commits the next epoch with a wrap for every active member, as a finished
// rotation does
func rotateTo(t *testing.T, e *avatarEnv, epoch int) {
	t.Helper()
	ctx := context.Background()
	if _, err := e.pool.Exec(ctx,
		`INSERT INTO album_epochs (album_id, epoch) VALUES ($1, $2)`, e.album, epoch); err != nil {
		t.Fatalf("commit epoch %d: %v", epoch, err)
	}
	if _, err := e.pool.Exec(ctx, `
		INSERT INTO album_epoch_wraps
		  (album_id, epoch, recipient_token, ek_pub, wrap_nonce, wrap_tag_ct,
		   sender_token, sender_sig)
		SELECT $1, $2, m.member_token, $3, $4, $5, m.member_token, $6
		FROM album_members m
		WHERE m.album_id = $1 AND m.revoked_at IS NULL`,
		e.album, epoch, make([]byte, 32), make([]byte, 12), make([]byte, 48),
		make([]byte, 64)); err != nil {
		t.Fatalf("wrap epoch %d: %v", epoch, err)
	}
}

// Sealed under the given epoch, which the key's first four bytes name
func sealedAt(epoch byte) []byte {
	k := make([]byte, 65)
	k[3] = epoch
	return k
}

// A removed member still holds the old key, so after rotation nothing may be
// confirmed or reserved under it, and only a reseal goes through
func TestCover_RotationRefusesTheOldKeyAndTakesTheReseal(t *testing.T) {
	e := newAvatarEnv(t)
	covers := repository.NewCoverRepository(e.pool, repository.StorageQuota{})
	ctx := context.Background()
	t.Cleanup(func() {
		_, _ = e.pool.Exec(ctx, `DELETE FROM media_object_cleanup WHERE storage_key LIKE 'cover-%'`)
	})

	old := coverUpload(e, "cover-o")
	if err := covers.Reserve(ctx, old); err != nil {
		t.Fatalf("reserve at epoch 0: %v", err)
	}
	rotateTo(t, e, 1)

	if _, err := covers.Confirm(ctx, e.album, e.admin, old.CoverID, old.StorageKey); !errors.Is(err, repository.ErrEpochMismatch) {
		t.Fatalf("confirm under the old key = %v, want ErrEpochMismatch", err)
	}
	if err := covers.Reserve(ctx, coverUpload(e, "cover-o2")); !errors.Is(err, repository.ErrEpochMismatch) {
		t.Fatalf("reserve under the old key = %v, want ErrEpochMismatch", err)
	}

	resealed := coverUpload(e, "cover-n")
	resealed.KeyCT = sealedAt(1)
	if err := covers.Reserve(ctx, resealed); err != nil {
		t.Fatalf("reserve resealed: %v", err)
	}
	if _, err := covers.Confirm(ctx, e.album, e.admin, resealed.CoverID, resealed.StorageKey); err != nil {
		t.Fatalf("confirm resealed: %v", err)
	}
	if got, _ := listedCover(t, e); got == nil || got.CoverID != resealed.CoverID {
		t.Fatalf("listed cover = %+v, want the resealed upload", got)
	}
}

func TestCover_PendingRotationFreezesCovers(t *testing.T) {
	e := newAvatarEnv(t)
	covers := repository.NewCoverRepository(e.pool, repository.StorageQuota{})
	ctx := context.Background()
	t.Cleanup(func() {
		_, _ = e.pool.Exec(ctx, `DELETE FROM media_object_cleanup WHERE storage_key LIKE 'cover-%'`)
	})

	up := coverUpload(e, "cover-r")
	if err := covers.Reserve(ctx, up); err != nil {
		t.Fatalf("reserve: %v", err)
	}
	if _, err := e.pool.Exec(ctx,
		`UPDATE albums SET rotation_required = TRUE WHERE id = $1`, e.album); err != nil {
		t.Fatalf("mark rotation: %v", err)
	}
	if _, err := covers.Confirm(ctx, e.album, e.admin, up.CoverID, up.StorageKey); !errors.Is(err, repository.ErrPendingRotation) {
		t.Fatalf("confirm during rotation = %v, want ErrPendingRotation", err)
	}
	if err := covers.Reserve(ctx, coverUpload(e, "cover-r2")); !errors.Is(err, repository.ErrPendingRotation) {
		t.Fatalf("reserve during rotation = %v, want ErrPendingRotation", err)
	}
}

// Confirm names the object it checked, a re-reservation under the same id is
// not confirmed in its place
func TestCover_ConfirmOnlyTheCheckedObject(t *testing.T) {
	e := newAvatarEnv(t)
	covers := repository.NewCoverRepository(e.pool, repository.StorageQuota{})
	ctx := context.Background()
	t.Cleanup(func() {
		_, _ = e.pool.Exec(ctx, `DELETE FROM media_object_cleanup WHERE storage_key LIKE 'cover-%'`)
	})

	first := coverUpload(e, "cover-1")
	if err := covers.Reserve(ctx, first); err != nil {
		t.Fatalf("reserve: %v", err)
	}
	again := *first
	again.StorageKey, again.BlobSHA256 = "cover-2", bytes.Repeat([]byte{2}, 32)
	if err := covers.Reserve(ctx, &again); err != nil {
		t.Fatalf("re-reserve: %v", err)
	}
	if _, err := covers.Confirm(ctx, e.album, e.admin, first.CoverID, "cover-1"); !errors.Is(err, repository.ErrCoverNotFound) {
		t.Fatalf("confirm of the replaced object = %v, want ErrCoverNotFound", err)
	}
	if got, _ := listedCover(t, e); got != nil {
		t.Fatalf("an unchecked object was confirmed: %+v", got)
	}
}

// A failed check on the first object must not take the reservation that
// replaced it under the same id
func TestCover_StaleDropKeepsTheReplacement(t *testing.T) {
	e := newAvatarEnv(t)
	covers := repository.NewCoverRepository(e.pool, repository.StorageQuota{})
	ctx := context.Background()
	t.Cleanup(func() {
		_, _ = e.pool.Exec(ctx, `DELETE FROM media_object_cleanup WHERE storage_key LIKE 'cover-%'`)
	})

	first := coverUpload(e, "cover-a1")
	if err := covers.Reserve(ctx, first); err != nil {
		t.Fatalf("reserve: %v", err)
	}
	again := *first
	again.StorageKey, again.BlobSHA256 = "cover-a2", bytes.Repeat([]byte{3}, 32)
	if err := covers.Reserve(ctx, &again); err != nil {
		t.Fatalf("re-reserve: %v", err)
	}
	if keys, err := covers.DropPending(ctx, e.album, first.CoverID, "cover-a1"); err != nil || len(keys) != 0 {
		t.Fatalf("stale drop = %v, %v, want nothing removed", keys, err)
	}
	if _, err := covers.Confirm(ctx, e.album, e.admin, again.CoverID, "cover-a2"); err != nil {
		t.Fatalf("the replacement was lost: %v", err)
	}
}
