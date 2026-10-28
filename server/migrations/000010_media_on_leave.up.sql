-- What happens to a member's photos when they leave or are removed. FALSE
-- keeps them in the album, which is the default
ALTER TABLE users ADD COLUMN delete_media_on_leave BOOLEAN NOT NULL DEFAULT FALSE;
