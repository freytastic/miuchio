-- The owner's chosen cover. The id is a media row the server already knows,
-- so choosing one reveals nothing new. Deleting that photo falls back to the
-- newest one
ALTER TABLE albums
    ADD COLUMN cover_media_id UUID REFERENCES media(id) ON DELETE SET NULL;
