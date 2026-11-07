-- Login and session lookups refuse a suspended account
ALTER TABLE users ADD COLUMN suspended_at TIMESTAMPTZ;

-- Rises on every re-add, which reuses the member token, so a phone that
-- missed the removal still sees a new membership
ALTER TABLE album_members ADD COLUMN joins INTEGER NOT NULL DEFAULT 1;

-- Keyed hashes under their own subkey, so a row names neither person and
-- cannot be joined to album memberships
CREATE TABLE blocks (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    blocker_hash BYTEA NOT NULL,
    -- Order independent, so one lookup covers both directions
    pair_hash    BYTEA NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT date_trunc('hour', now()),
    UNIQUE (blocker_hash, pair_hash)
);

CREATE INDEX idx_blocks_pair ON blocks(pair_hash);

-- An allegation for a person to review, never acted on automatically. Members
-- are named by token plus a copy of their sealed user link, so a report
-- survives the album without holding a user id in the clear
CREATE TABLE reports (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    album_id       UUID NOT NULL,
    media_id       UUID,
    -- Pins the upload itself, since a deleted photo's id can be reused
    media_upload   UUID,
    kind           TEXT NOT NULL CHECK (kind IN ('photo', 'person')),
    subject_token  BYTEA NOT NULL,
    subject_enc    BYTEA NOT NULL,
    reporter_token BYTEA NOT NULL,
    reporter_enc   BYTEA NOT NULL,
    -- Sealed on the reporter's phone to the moderation key, opaque here
    sealed         BYTEA NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at    TIMESTAMPTZ,
    resolution     TEXT CHECK (resolution IN ('dismissed', 'inconclusive', 'removed', 'suspended')),
    CHECK ((resolved_at IS NULL) = (resolution IS NULL)),
    CHECK (kind <> 'photo' OR (media_id IS NOT NULL AND media_upload IS NOT NULL))
);

CREATE INDEX idx_reports_open ON reports(created_at) WHERE resolved_at IS NULL;
CREATE INDEX idx_reports_resolved ON reports(resolved_at) WHERE resolved_at IS NOT NULL;

-- Fixed decision codes only, so no report content outlives the report
CREATE TABLE moderation_actions (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    report_id  UUID,
    action     TEXT NOT NULL CHECK (action IN ('dismissed', 'inconclusive', 'removed', 'suspended', 'unsuspended')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_moderation_actions_report ON moderation_actions(report_id);
