package repository_test

import (
	"context"
	"testing"

	"github.com/freytastic/miuchio/internal/repository"
	"github.com/google/uuid"
)

// Uses a real database because the target's setting is read through its sealed user link
func TestRevokeMember_RemovalFollowsTheTargetsSetting(t *testing.T) {
	for _, del := range []bool{false, true} {
		env := newSummaryEnv(t)
		ctx := context.Background()
		owner, joiner := env.seedUser(t), env.seedUser(t)
		album, admin, err := env.repo.CreateWithAdmin(ctx, []byte("departing"), owner)
		if err != nil {
			t.Fatalf("create album: %v", err)
		}
		t.Cleanup(func() {
			_, _ = env.pool.Exec(ctx, `DELETE FROM albums WHERE id = $1`, album.ID)
		})
		member, err := env.repo.AddMember(ctx, album.ID, joiner, "member")
		if err != nil {
			t.Fatalf("add member: %v", err)
		}
		if err := repository.NewUserRepository(env.pool).SetDeleteMediaOnLeave(ctx, joiner, del); err != nil {
			t.Fatalf("set preference: %v", err)
		}
		id := uuid.New()
		key := "blob/" + id.String()
		t.Cleanup(func() {
			_, _ = env.pool.Exec(ctx, `DELETE FROM media_object_cleanup WHERE storage_key = $1`, key)
		})
		if _, err := env.pool.Exec(ctx,
			`INSERT INTO media (id, album_id, uploader_token, storage_key,
			   wrap_nonce, wrap_tag_ct, epoch_tag, blob_size, blob_sha256, media_type, confirmed)
			 VALUES ($1, $2, $3, $4, $5, $6, 0, 10, $7, 'photo', TRUE)`,
			id, album.ID, member, key, make([]byte, 12), make([]byte, 48), make([]byte, 32),
		); err != nil {
			t.Fatalf("insert photo: %v", err)
		}

		rev, err := env.repo.RevokeMemberTx(ctx, album.ID, admin, member, repository.PreferredMedia)
		if err != nil {
			t.Fatalf("revoke: %v", err)
		}
		var left int
		if err := env.pool.QueryRow(ctx, `SELECT count(*) FROM media WHERE id = $1`, id).Scan(&left); err != nil {
			t.Fatal(err)
		}
		if want := map[bool]int{false: 1, true: 0}[del]; left != want {
			t.Errorf("delete=%v: %d photos left, want %d", del, left, want)
		}
		if del && len(rev.Media.MediaIDs) != 1 {
			t.Errorf("delete=true: reported %d deleted photos, want 1", len(rev.Media.MediaIDs))
		}
	}
}
