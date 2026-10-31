-- The cover the owner chose: either one of the album's photos, or an image
-- sealed under the album MK that lives only here. No confirmed row means the
-- newest photo leads
CREATE TABLE album_covers (
    -- Client chosen for uploads, because it is bound into the cover's AEAD AAD
    cover_id        UUID PRIMARY KEY,
    album_id        UUID NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    set_by          BYTEA NOT NULL REFERENCES album_member_identities(member_token) ON DELETE CASCADE,
    -- Deleting the photo falls back to the newest
    media_id        UUID REFERENCES media(id) ON DELETE CASCADE,
    storage_key     TEXT,
    blob_size       BIGINT,
    blob_sha256     BYTEA,
    -- u32_be(epoch) || DEK sealed under that epoch's MK, opaque to the server
    key_ct          BYTEA,
    confirmed       BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT date_trunc('hour', now()),
    CHECK ((media_id IS NULL) = (storage_key IS NOT NULL)),
    CHECK (storage_key IS NULL OR (blob_size IS NOT NULL AND blob_sha256 IS NOT NULL AND key_ct IS NOT NULL))
);

CREATE UNIQUE INDEX idx_album_covers_current ON album_covers(album_id) WHERE confirmed = TRUE;
CREATE INDEX idx_album_covers_album ON album_covers(album_id);
CREATE INDEX idx_album_covers_pending ON album_covers(created_at) WHERE confirmed = FALSE;
CREATE INDEX idx_album_covers_set_by ON album_covers(set_by);
