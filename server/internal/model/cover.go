package model

import (
	"time"

	"github.com/google/uuid"
)

// Exactly one of MediaID and StorageKey is set
type AlbumCover struct {
	CoverID    uuid.UUID
	AlbumID    uuid.UUID
	SetBy      []byte
	MediaID    *uuid.UUID
	StorageKey string
	BlobSize   int64
	BlobSHA256 []byte
	KeyCT      []byte
	Confirmed  bool
	CreatedAt  time.Time
}

// What members need to show the album's chosen cover. An uploaded cover
// carries its sealed key, a chosen photo only its media id
type CoverRef struct {
	CoverID    uuid.UUID
	SetBy      []byte
	MediaID    *uuid.UUID
	BlobSize   int64
	BlobSHA256 []byte
	KeyCT      []byte
}
