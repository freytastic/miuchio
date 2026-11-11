-- Counts handovers, separate from the key epoch since a handover alone makes
-- no new key
ALTER TABLE albums ADD COLUMN admin_term INTEGER NOT NULL DEFAULT 0;

-- The membership generation the member proved they joined
ALTER TABLE album_members ADD COLUMN acked_joins INTEGER NOT NULL DEFAULT 0;

-- Per wrap because an invite re-wraps old keys, so one recipient's signer can
-- differ from the epoch's creator
ALTER TABLE album_epoch_wraps ADD COLUMN sender_generation INTEGER NOT NULL DEFAULT 1;

-- An admin's signed statement that one membership may rotate. Holds its own
-- copy of the keys and no reference to the member rows, so a wrap stays
-- verifiable after its signer leaves or deletes their account
CREATE TABLE member_notes (
    album_id     UUID NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    member_token BYTEA NOT NULL,
    generation   INTEGER NOT NULL,
    issuer_term  INTEGER NOT NULL,
    ik_pub       BYTEA NOT NULL,
    lk_pub       BYTEA NOT NULL,
    sig          BYTEA NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT date_trunc('hour', now()),
    PRIMARY KEY (album_id, member_token, generation, issuer_term)
);

-- The outgoing admin's signed statement naming the next one, chained by
-- prev_hash. operation_id and request_hash are private to the caller and
-- only make a retry return its first result
CREATE TABLE album_handovers (
    album_id       UUID NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    term           INTEGER NOT NULL,
    prev_hash      BYTEA NOT NULL,
    old_token      BYTEA NOT NULL,
    new_token      BYTEA NOT NULL,
    new_generation INTEGER NOT NULL,
    new_ik_pub     BYTEA NOT NULL,
    new_lk_pub     BYTEA NOT NULL,
    mode           SMALLINT NOT NULL CHECK (mode IN (1, 2)),
    delete_media   BOOLEAN NOT NULL,
    sig            BYTEA NOT NULL,
    operation_id   UUID NOT NULL UNIQUE,
    request_hash   BYTEA NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT date_trunc('hour', now()),
    PRIMARY KEY (album_id, term)
);
