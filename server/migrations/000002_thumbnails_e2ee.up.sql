-- Each thumbnail has its own DEK, wrapped under the epoch MK with the same AAD
-- as the file DEK (album_id ‖ u32_be(epoch)). All nullable, videos and older
-- rows have no thumbnail

ALTER TABLE media ADD COLUMN thumb_wrap_nonce BYTEA;
ALTER TABLE media ADD COLUMN thumb_wrap_tag_ct BYTEA;
ALTER TABLE media ADD COLUMN thumb_size BIGINT;
ALTER TABLE media ADD COLUMN thumb_sha256 BYTEA;
