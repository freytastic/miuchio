-- Storage quota sums an account's uploads through its member tokens
CREATE INDEX idx_media_uploader ON media(uploader_token);
