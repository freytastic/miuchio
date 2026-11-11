package authority

import (
	"context"
	"crypto/ed25519"

	"github.com/freytastic/miuchio/internal/crypto"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type SignedNote struct {
	Note
	Sig []byte
}

type SignedHandover struct {
	Handover
	Sig []byte
}

func VerifyNote(n SignedNote, issuerIK []byte) error {
	return crypto.VerifyEd25519(ed25519.PublicKey(issuerIK), NoteMsg(n.Note), n.Sig)
}

func VerifyHandover(h SignedHandover, oldAdminIK []byte) error {
	return crypto.VerifyEd25519(ed25519.PublicKey(oldAdminIK), HandoverMsg(h.Handover), h.Sig)
}

type Repo struct {
	db *pgxpool.Pool
}

func NewRepo(db *pgxpool.Pool) *Repo {
	return &Repo{db: db}
}

// Runs inside the transaction that creates the membership it vouches for
// A retried request repeats the same bytes, so a duplicate is left alone
func InsertNote(ctx context.Context, tx pgx.Tx, n SignedNote) error {
	_, err := tx.Exec(ctx,
		`INSERT INTO member_notes
		 (album_id, member_token, generation, issuer_term, ik_pub, lk_pub, sig)
		 VALUES ($1, $2, $3, $4, $5, $6, $7)
		 ON CONFLICT (album_id, member_token, generation, issuer_term) DO NOTHING`,
		n.AlbumID, n.MemberToken, int32(n.Generation), int32(n.IssuerTerm), n.IKPub, n.LKPub, n.Sig,
	)
	return err
}

// Callers hold the album lock
func HasNote(ctx context.Context, tx pgx.Tx, albumID uuid.UUID, token []byte, generation int) (bool, error) {
	var ok bool
	err := tx.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM member_notes
		 WHERE album_id = $1 AND member_token = $2 AND generation = $3)`,
		albumID, token, generation,
	).Scan(&ok)
	return ok, err
}

func (r *Repo) AdminTerm(ctx context.Context, albumID uuid.UUID) (int, error) {
	var term int
	err := r.db.QueryRow(ctx, `SELECT admin_term FROM albums WHERE id = $1`, albumID).Scan(&term)
	return term, err
}

// Every note of each active member's current generation
func (r *Repo) ActiveNotes(ctx context.Context, albumID uuid.UUID) ([]SignedNote, error) {
	return r.notes(ctx,
		`SELECT n.member_token, n.generation, n.issuer_term, n.ik_pub, n.lk_pub, n.sig
		 FROM member_notes n
		 JOIN album_members m ON m.album_id = n.album_id
		   AND m.member_token = n.member_token AND m.joins = n.generation
		 WHERE n.album_id = $1 AND m.revoked_at IS NULL
		 ORDER BY n.member_token, n.issuer_term`,
		albumID, albumID)
}

// Serves a departed signer too, since the note rows outlive the membership
func (r *Repo) NotesFor(ctx context.Context, albumID uuid.UUID, token []byte, generation int) ([]SignedNote, error) {
	return r.notes(ctx,
		`SELECT member_token, generation, issuer_term, ik_pub, lk_pub, sig
		 FROM member_notes
		 WHERE album_id = $1 AND member_token = $2 AND generation = $3
		 ORDER BY issuer_term`,
		albumID, albumID, token, generation)
}

func (r *Repo) notes(ctx context.Context, sql string, albumID uuid.UUID, args ...any) ([]SignedNote, error) {
	rows, err := r.db.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SignedNote
	for rows.Next() {
		n := SignedNote{Note: Note{AlbumID: albumID}}
		var generation, term int32
		if err := rows.Scan(&n.MemberToken, &generation, &term, &n.IKPub, &n.LKPub, &n.Sig); err != nil {
			return nil, err
		}
		n.Generation, n.IssuerTerm = uint32(generation), uint32(term)
		out = append(out, n)
	}
	return out, rows.Err()
}

func (r *Repo) Handovers(ctx context.Context, albumID uuid.UUID) ([]SignedHandover, error) {
	rows, err := r.db.Query(ctx,
		`SELECT term, prev_hash, old_token, new_token, new_generation,
		        new_ik_pub, new_lk_pub, mode, delete_media, sig
		 FROM album_handovers WHERE album_id = $1 ORDER BY term`,
		albumID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SignedHandover
	for rows.Next() {
		h := SignedHandover{Handover: Handover{AlbumID: albumID}}
		var term, generation int32
		var mode int16
		if err := rows.Scan(&term, &h.PrevHash, &h.OldToken, &h.NewToken, &generation,
			&h.NewIKPub, &h.NewLKPub, &mode, &h.DeleteMedia, &h.Sig); err != nil {
			return nil, err
		}
		h.Term, h.NewGeneration, h.Mode = uint32(term), uint32(generation), byte(mode)
		out = append(out, h)
	}
	return out, rows.Err()
}
