package authority

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/freytastic/miuchio/internal/apierr"
	"github.com/google/uuid"
	"github.com/gorilla/mux"
)

type reader interface {
	AdminTerm(ctx context.Context, albumID uuid.UUID) (int, error)
	ActiveNotes(ctx context.Context, albumID uuid.UUID) ([]SignedNote, error)
	Handovers(ctx context.Context, albumID uuid.UUID) ([]SignedHandover, error)
}

type Handler struct {
	repo reader
}

func NewHandler(repo reader) *Handler {
	return &Handler{repo: repo}
}

type NoteJSON struct {
	MemberToken string `json:"member_token"`
	Generation  uint32 `json:"generation"`
	IssuerTerm  uint32 `json:"issuer_term"`
	IKPub       string `json:"ik_pub"`
	LKPub       string `json:"lk_pub"`
	Sig         string `json:"sig"`
}

func NotesJSON(notes []SignedNote) []NoteJSON {
	out := make([]NoteJSON, len(notes))
	for i, n := range notes {
		out[i] = NoteJSON{
			MemberToken: b64(n.MemberToken),
			Generation:  n.Generation,
			IssuerTerm:  n.IssuerTerm,
			IKPub:       b64(n.IKPub),
			LKPub:       b64(n.LKPub),
			Sig:         b64(n.Sig),
		}
	}
	return out
}

// Decode checks field lengths, the signature is the caller's to verify
func (j NoteJSON) Decode(albumID uuid.UUID) (SignedNote, error) {
	n := SignedNote{Note: Note{AlbumID: albumID, Generation: j.Generation, IssuerTerm: j.IssuerTerm}}
	for _, f := range []struct {
		dst  *[]byte
		src  string
		name string
		size int
	}{
		{&n.MemberToken, j.MemberToken, "member_token", TokenLen},
		{&n.IKPub, j.IKPub, "ik_pub", KeyLen},
		{&n.LKPub, j.LKPub, "lk_pub", KeyLen},
		{&n.Sig, j.Sig, "sig", ed25519.SignatureSize},
	} {
		b, err := base64.StdEncoding.DecodeString(f.src)
		if err != nil || len(b) != f.size {
			return SignedNote{}, apierr.Validation("note." + f.name + " must be " + strconv.Itoa(f.size) + " bytes of base64")
		}
		*f.dst = b
	}
	if n.Generation == 0 {
		return SignedNote{}, apierr.Validation("note.generation must be >= 1")
	}
	return n, nil
}

type handoverJSON struct {
	Term          uint32 `json:"term"`
	PrevHash      string `json:"prev_hash"`
	OldToken      string `json:"old_token"`
	NewToken      string `json:"new_token"`
	NewGeneration uint32 `json:"new_generation"`
	NewIKPub      string `json:"new_ik_pub"`
	NewLKPub      string `json:"new_lk_pub"`
	Mode          byte   `json:"mode"`
	DeleteMedia   bool   `json:"delete_media"`
	Sig           string `json:"sig"`
}

// ListNotes handles GET /api/v1/albums/{id}/notes
func (h *Handler) ListNotes(w http.ResponseWriter, r *http.Request) {
	albumID, ok := albumID(w, r)
	if !ok {
		return
	}
	term, err := h.repo.AdminTerm(r.Context(), albumID)
	if err != nil {
		apierr.Write(w, r, apierr.Internal("admin term lookup failed").WithCause(err))
		return
	}
	notes, err := h.repo.ActiveNotes(r.Context(), albumID)
	if err != nil {
		apierr.Write(w, r, apierr.Internal("notes lookup failed").WithCause(err))
		return
	}
	writeJSON(w, map[string]any{"admin_term": term, "notes": NotesJSON(notes)})
}

// ListHandovers handles GET /api/v1/albums/{id}/handovers
func (h *Handler) ListHandovers(w http.ResponseWriter, r *http.Request) {
	albumID, ok := albumID(w, r)
	if !ok {
		return
	}
	chain, err := h.repo.Handovers(r.Context(), albumID)
	if err != nil {
		apierr.Write(w, r, apierr.Internal("handovers lookup failed").WithCause(err))
		return
	}
	out := make([]handoverJSON, len(chain))
	for i, c := range chain {
		out[i] = handoverJSON{
			Term:          c.Term,
			PrevHash:      b64(c.PrevHash),
			OldToken:      b64(c.OldToken),
			NewToken:      b64(c.NewToken),
			NewGeneration: c.NewGeneration,
			NewIKPub:      b64(c.NewIKPub),
			NewLKPub:      b64(c.NewLKPub),
			Mode:          c.Mode,
			DeleteMedia:   c.DeleteMedia,
			Sig:           b64(c.Sig),
		}
	}
	writeJSON(w, map[string]any{"handovers": out})
}

func albumID(w http.ResponseWriter, r *http.Request) (uuid.UUID, bool) {
	id, err := uuid.Parse(mux.Vars(r)["id"])
	if err != nil {
		apierr.Write(w, r, apierr.Validation("invalid album id").WithCause(err))
		return uuid.Nil, false
	}
	return id, true
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func b64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }
