package authority

import (
	"crypto/sha256"
	"encoding/binary"

	"github.com/freytastic/miuchio/internal/crypto"
	"github.com/google/uuid"
)

const (
	PermRotate = byte(0x01)

	ModeStay  = byte(1)
	ModeLeave = byte(2)

	TokenLen = 32
	KeyLen   = 32
	HashLen  = sha256.Size
)

// Note is an admin's statement that one membership may rotate. Generation is
// the membership's joins counter, so a rejoin on the same token needs a new one
type Note struct {
	AlbumID     uuid.UUID
	MemberToken []byte
	Generation  uint32
	IKPub       []byte
	LKPub       []byte
	IssuerTerm  uint32
}

// NoteMsg is "member-note-v1" ‖ album_id(16) ‖ member_token(32) ‖
// u32_be(generation) ‖ ik_pub(32) ‖ lk_pub(32) ‖ u32_be(issuer_term) ‖ perm(1)
func NoteMsg(n Note) []byte {
	out := make([]byte, 0, len(crypto.SaltMemberNote)+16+TokenLen+4+KeyLen+KeyLen+4+1)
	out = append(out, crypto.SaltMemberNote...)
	out = append(out, n.AlbumID[:]...)
	out = append(out, n.MemberToken...)
	out = binary.BigEndian.AppendUint32(out, n.Generation)
	out = append(out, n.IKPub...)
	out = append(out, n.LKPub...)
	out = binary.BigEndian.AppendUint32(out, n.IssuerTerm)
	return append(out, PermRotate)
}

// Handover is the outgoing admin's statement that NewToken holds Term
type Handover struct {
	AlbumID       uuid.UUID
	Term          uint32
	PrevHash      []byte
	OldToken      []byte
	NewToken      []byte
	NewGeneration uint32
	NewIKPub      []byte
	NewLKPub      []byte
	Mode          byte
	DeleteMedia   bool
}

// HandoverMsg is "admin-handover-v1" ‖ album_id(16) ‖ u32_be(term) ‖
// prev_hash(32) ‖ old_token(32) ‖ new_token(32) ‖ u32_be(new_generation) ‖
// new_ik_pub(32) ‖ new_lk_pub(32) ‖ mode(1) ‖ delete_media(1)
func HandoverMsg(h Handover) []byte {
	out := make([]byte, 0, len(crypto.SaltAdminHandover)+16+4+HashLen+TokenLen+TokenLen+4+KeyLen+KeyLen+2)
	out = append(out, crypto.SaltAdminHandover...)
	out = append(out, h.AlbumID[:]...)
	out = binary.BigEndian.AppendUint32(out, h.Term)
	out = append(out, h.PrevHash...)
	out = append(out, h.OldToken...)
	out = append(out, h.NewToken...)
	out = binary.BigEndian.AppendUint32(out, h.NewGeneration)
	out = append(out, h.NewIKPub...)
	out = append(out, h.NewLKPub...)
	out = append(out, h.Mode)
	if h.DeleteMedia {
		return append(out, 1)
	}
	return append(out, 0)
}

// The first handover of an album chains from zeros
var ZeroHash = make([]byte, HashLen)

// HandoverHash is SHA256(msg ‖ sig), the link the next handover signs
func HandoverHash(msg, sig []byte) []byte {
	h := sha256.New()
	h.Write(msg)
	h.Write(sig)
	return h.Sum(nil)
}
