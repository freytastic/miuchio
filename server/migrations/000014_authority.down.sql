DROP TABLE IF EXISTS album_handovers;
DROP TABLE IF EXISTS member_notes;
ALTER TABLE album_epoch_wraps DROP COLUMN IF EXISTS sender_generation;
ALTER TABLE album_members DROP COLUMN IF EXISTS acked_joins;
ALTER TABLE albums DROP COLUMN IF EXISTS admin_term;
