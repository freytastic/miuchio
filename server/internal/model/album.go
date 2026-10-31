package model

import (
	"time"

	"github.com/google/uuid"
)

type Album struct {
	ID        uuid.UUID `json:"id"`
	NameCT    []byte    `json:"name_ct"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

type AlbumMember struct {
	AlbumID     uuid.UUID  `json:"album_id"`
	MemberToken []byte     `json:"member_token"`
	Role        string     `json:"role"`
	RevokedAt   *time.Time `json:"revoked_at,omitempty"`
}

type AlbumWithMemberInfo struct {
	Album
	UserRole    string `json:"user_role"`
	MemberToken []byte `json:"member_token"`
	Summary     AlbumSummary
	// Nil while the newest photo leads
	Cover *CoverRef
}

type AlbumSummary struct {
	MediaCount        int
	ActiveMemberCount int
	LatestActivityAt  *time.Time
	MediaGeneration   int64
	RotationRequired  bool
	PreviewMedia      []PreviewMedia
	MemberPreviews    []MemberPreview
}

type PreviewMedia struct {
	MediaID        uuid.UUID
	EpochTag       int
	ThumbWrapNonce []byte
	ThumbWrapTagCT []byte
	ThumbSize      int64
	ThumbSHA256    []byte
}

// Excludes identity keys bcs shelf previews are not trust verified
type MemberPreview struct {
	MemberToken []byte
	NameCT      []byte
	Avatar      *AvatarRef
}

// MemberProfile holds the public bytes members need to render each other. The
// name and the avatar key are sealed under the album MK
type MemberProfile struct {
	IKPub  []byte     `json:"ik_pub"`
	LKPub  []byte     `json:"lk_pub"`
	NameCT []byte     `json:"name_ct,omitempty"`
	Avatar *AvatarRef `json:"-"`
}

type MemberWithProfile struct {
	MemberToken []byte        `json:"member_token"`
	Role        string        `json:"role"`
	Revoked     bool          `json:"revoked"`
	JoinedAt    time.Time     `json:"joined_at"`
	Profile     MemberProfile `json:"profile"`
}
