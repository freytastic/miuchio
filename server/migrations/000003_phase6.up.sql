-- miuchio_id is the user's shareable 8 character Crockford base32 handle,
-- unrelated to the sealed user_handle on album_member_identities. NOT NULL
-- without a default, registration always sets it
ALTER TABLE users ADD COLUMN miuchio_id TEXT NOT NULL;
CREATE UNIQUE INDEX idx_users_miuchio_id ON users(miuchio_id);

-- Last epoch the member proved it installed through join_complete, NULL when
-- never acknowledged. Members behind for over 24h are flagged on set_epoch
ALTER TABLE album_member_identities ADD COLUMN last_received_epoch INT;
ALTER TABLE album_member_identities ADD COLUMN last_received_at TIMESTAMPTZ;
