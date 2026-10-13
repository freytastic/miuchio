CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- DEFAULT timestamps are quantized to the hour, so a database snapshot cannot
-- correlate who joined or uploaded within seconds of whom. Explicit timestamps
-- such as sessions.expires_at keep full precision

-- email_hmac = HMAC-SHA256(MIUCHIO_EMAIL_HMAC_KEY, lower(trim(email))). The raw
-- email never reaches disk, which also removes any "is this email registered"
-- oracle

-- No name or avatar here: both live encrypted per album, sealed under that
-- album's MK so only members can read them
CREATE TABLE users (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email_hmac      BYTEA UNIQUE NOT NULL,
    ik_pub          BYTEA,
    lk_pub          BYTEA,
    spk_pub         BYTEA,
    spk_sig         BYTEA,
    spk_ts          BIGINT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT date_trunc('hour', now()),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT date_trunc('hour', now())
);

CREATE TABLE sessions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash      BYTEA NOT NULL UNIQUE,
    expires_at      TIMESTAMPTZ NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT date_trunc('hour', now())
);
CREATE INDEX idx_sessions_user ON sessions(user_id);
CREATE INDEX idx_sessions_expires ON sessions(expires_at);

CREATE TABLE one_time_prekeys (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    opk_idx         INT NOT NULL,
    key_pub         BYTEA NOT NULL,
    consumed        BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT date_trunc('hour', now()),
    UNIQUE (user_id, opk_idx)
);
CREATE INDEX idx_opk_user_unconsumed ON one_time_prekeys(user_id) WHERE consumed = FALSE;

CREATE TABLE albums (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name_ct         BYTEA NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT date_trunc('hour', now()),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT date_trunc('hour', now())
);

-- Links user_id to member_token without storing it in the clear (see the
-- userlink package). user_handle is a deterministic HMAC for "which albums is
-- this user in", user_id_enc an AEAD blob for "which user owns this token".
-- Without MIUCHIO_USER_LINK_KEY a snapshot does not reveal which user owns a
-- token. There is deliberately no FK to users(id), account deletion computes
-- the handle and deletes explicitly
CREATE TABLE album_member_identities (
    member_token    BYTEA PRIMARY KEY,
    user_handle     BYTEA NOT NULL,
    user_id_enc     BYTEA NOT NULL,
    album_id        UUID NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    joined_at       TIMESTAMPTZ NOT NULL DEFAULT date_trunc('hour', now()),
    UNIQUE (user_handle, album_id)
);
CREATE INDEX idx_amid_user_handle ON album_member_identities(user_handle);
CREATE INDEX idx_amid_album ON album_member_identities(album_id);

-- name_ct is the member's name sealed under this album's MK, opaque to the
-- server. NULL until the member publishes one
CREATE TABLE album_members (
    album_id        UUID NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    member_token    BYTEA NOT NULL REFERENCES album_member_identities(member_token) ON DELETE CASCADE,
    role            TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('admin', 'co-admin', 'member')),
    revoked_at      TIMESTAMPTZ,
    name_ct         BYTEA,
    PRIMARY KEY (album_id, member_token)
);

-- epoch_sig is Ed25519 over (album_id ‖ epoch ‖ member_set_hash ‖ wraps_hash),
-- verified against the admin's IK before the row is written
CREATE TABLE album_epochs (
    album_id        UUID NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    epoch           INT NOT NULL,
    started_at      TIMESTAMPTZ NOT NULL DEFAULT date_trunc('hour', now()),
    epoch_sig       BYTEA,
    PRIMARY KEY (album_id, epoch)
);

CREATE TABLE album_epoch_wraps (
    album_id        UUID NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    epoch           INT NOT NULL,
    recipient_token BYTEA NOT NULL REFERENCES album_member_identities(member_token) ON DELETE CASCADE,
    ek_pub          BYTEA NOT NULL,
    opk_idx_used    INT,
    wrap_nonce      BYTEA NOT NULL,
    wrap_tag_ct     BYTEA NOT NULL,
    sender_token    BYTEA NOT NULL REFERENCES album_member_identities(member_token),
    sender_sig      BYTEA NOT NULL,
    delivered_at    TIMESTAMPTZ NOT NULL DEFAULT date_trunc('hour', now()),
    PRIMARY KEY (album_id, epoch, recipient_token)
);

-- Two phase upload: a reservation inserts a pending row, the client PUTs to S3,
-- and confirmation checks size and SHA256 before setting confirmed. Abandoned
-- pending rows are swept. storage_key is random and never carries album_id
CREATE TABLE media (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    album_id        UUID NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    uploader_token  BYTEA NOT NULL REFERENCES album_member_identities(member_token),
    storage_key     TEXT NOT NULL,
    thumb_key       TEXT,
    wrap_nonce      BYTEA NOT NULL,
    wrap_tag_ct     BYTEA NOT NULL,
    epoch_tag       INT NOT NULL,
    blob_size       BIGINT NOT NULL,
    blob_sha256     BYTEA NOT NULL,
    media_type      TEXT NOT NULL CHECK (media_type IN ('photo', 'video')),
    mime_type       TEXT,
    confirmed       BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT date_trunc('hour', now())
);
CREATE INDEX idx_media_album ON media(album_id, created_at DESC) WHERE confirmed = TRUE;
CREATE INDEX idx_media_pending ON media(created_at) WHERE confirmed = FALSE;

CREATE TABLE manifests (
    album_id        UUID NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    version         BIGINT NOT NULL,
    epoch           INT NOT NULL,
    payload         BYTEA NOT NULL,
    payload_hash    BYTEA NOT NULL,
    prev_hash       BYTEA,
    signer_token    BYTEA NOT NULL REFERENCES album_member_identities(member_token),
    signature       BYTEA NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT date_trunc('hour', now()),
    PRIMARY KEY (album_id, version)
);

CREATE TABLE invite_blobs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    album_id        UUID NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    payload         BYTEA NOT NULL,
    signer_token    BYTEA NOT NULL REFERENCES album_member_identities(member_token),
    signature       BYTEA NOT NULL,
    expires_at      TIMESTAMPTZ NOT NULL,
    consumed_at     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT date_trunc('hour', now())
);

CREATE TABLE invite_links (
    code            TEXT PRIMARY KEY,
    blob_id         UUID NOT NULL REFERENCES invite_blobs(id) ON DELETE CASCADE,
    expires_at      TIMESTAMPTZ NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT date_trunc('hour', now())
);

-- Append only audit of SPK rotations. IP and User-Agent are deliberately not
-- stored, they would build a long term device fingerprint per user
CREATE TABLE spk_rotations (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    old_spk_ts  BIGINT,
    new_spk_ts  BIGINT NOT NULL,
    rotated_at  TIMESTAMPTZ NOT NULL DEFAULT date_trunc('hour', now())
);
CREATE INDEX idx_spk_rotations_user ON spk_rotations(user_id, rotated_at DESC);
