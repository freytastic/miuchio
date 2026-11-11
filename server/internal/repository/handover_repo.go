package repository

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"errors"

	"github.com/freytastic/miuchio/internal/e2ee/authority"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

var (
	ErrStaleTerm           = errors.New("handover: the admin term moved on")
	ErrSuccessorIneligible = errors.New("handover: successor cannot take the album")
	ErrHandoverSig         = errors.New("handover: signature does not cover the album's locked state")
	ErrHandoverReused      = errors.New("handover: operation id already used for another request")
	ErrHandoverNotFound    = errors.New("handover: no such operation")
)

type HandoverRequest struct {
	AlbumID     uuid.UUID
	CallerToken []byte
	NewToken    []byte
	Term        uint32
	Mode        byte
	DeleteMedia bool
	Sig         []byte
	OperationID uuid.UUID
}

// Everything the caller chose, so a reused operation id with other content
// is told apart from a retry
func (q HandoverRequest) hash() []byte {
	h := sha256.New()
	h.Write(q.AlbumID[:])
	h.Write(q.NewToken)
	h.Write(binary.BigEndian.AppendUint32(nil, q.Term))
	h.Write([]byte{q.Mode, boolByte(q.DeleteMedia)})
	h.Write(q.Sig)
	return h.Sum(nil)
}

func boolByte(b bool) byte {
	if b {
		return 1
	}
	return 0
}

type HandoverResult struct {
	Term     uint32
	Mode     byte
	OldToken []byte
	NewToken []byte
	// Set when this call committed the handover, empty on a replayed retry
	Committed bool
	Media     MediaRemoval
}

// HandoverTx moves the admin role to another member, and in leave mode
// revokes the old admin in the same transaction. The signed record is rebuilt
// from the locked rows, so a signature over anything stale fails to verify
func (r *AlbumRepository) HandoverTx(ctx context.Context, q HandoverRequest) (HandoverResult, error) {
	tx, err := r.DB.Begin(ctx)
	if err != nil {
		return HandoverResult{}, err
	}
	defer tx.Rollback(ctx)
	if err := lockAlbum(ctx, tx, q.AlbumID); err != nil {
		return HandoverResult{}, err
	}

	// Before the admin check, since a committed handover demoted the caller
	if prior, found, err := priorHandover(ctx, tx, q); err != nil || found {
		return prior, err
	}

	var role string
	var revoked bool
	var callerSealed []byte
	err = tx.QueryRow(ctx,
		`SELECT am.role, am.revoked_at IS NOT NULL, ami.user_id_enc
		 FROM album_members am
		 JOIN album_member_identities ami ON ami.member_token = am.member_token
		 WHERE am.album_id = $1 AND am.member_token = $2`,
		q.AlbumID, q.CallerToken,
	).Scan(&role, &revoked, &callerSealed)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && revoked) {
		return HandoverResult{}, ErrCallerRevoked
	}
	if err != nil {
		return HandoverResult{}, err
	}
	if role != "admin" {
		return HandoverResult{}, ErrNotAlbumAdmin
	}

	var term int32
	if err := tx.QueryRow(ctx,
		`SELECT admin_term FROM albums WHERE id = $1`, q.AlbumID,
	).Scan(&term); err != nil {
		return HandoverResult{}, err
	}
	if q.Term != uint32(term)+1 {
		return HandoverResult{}, ErrStaleTerm
	}

	// Joined means the receipt for this exact membership arrived, and the note
	// is what lets the others accept keys the successor signs
	var generation int32
	var successorSealed []byte
	err = tx.QueryRow(ctx,
		`SELECT am.joins, ami.user_id_enc
		 FROM album_members am
		 JOIN album_member_identities ami ON ami.member_token = am.member_token
		 WHERE am.album_id = $1 AND am.member_token = $2
		   AND am.revoked_at IS NULL AND am.acked_joins = am.joins
		   AND EXISTS (SELECT 1 FROM member_notes n
		     WHERE n.album_id = am.album_id AND n.member_token = am.member_token
		       AND n.generation = am.joins)`,
		q.AlbumID, q.NewToken,
	).Scan(&generation, &successorSealed)
	if errors.Is(err, pgx.ErrNoRows) || bytes.Equal(q.NewToken, q.CallerToken) {
		return HandoverResult{}, ErrSuccessorIneligible
	}
	if err != nil {
		return HandoverResult{}, err
	}
	callerID, err := r.linker.Open(callerSealed, q.CallerToken)
	if err != nil {
		return HandoverResult{}, ErrCallerRevoked
	}
	successorID, err := r.linker.Open(successorSealed, q.NewToken)
	if err != nil {
		return HandoverResult{}, ErrSuccessorIneligible
	}

	// FOR SHARE waits out an account deletion being accepted, so the album is
	// never handed to an account the deletion job has already enumerated
	rows, err := tx.Query(ctx,
		`SELECT id, deleting_at IS NOT NULL OR suspended_at IS NOT NULL, ik_pub, lk_pub
		 FROM users WHERE id = ANY($1) ORDER BY id FOR SHARE`,
		[]uuid.UUID{callerID, successorID},
	)
	if err != nil {
		return HandoverResult{}, err
	}
	type account struct {
		unavailable bool
		ik, lk      []byte
	}
	accounts := map[uuid.UUID]account{}
	for rows.Next() {
		var id uuid.UUID
		var a account
		if err := rows.Scan(&id, &a.unavailable, &a.ik, &a.lk); err != nil {
			rows.Close()
			return HandoverResult{}, err
		}
		accounts[id] = a
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return HandoverResult{}, err
	}
	caller, ok := accounts[callerID]
	if !ok || caller.unavailable {
		return HandoverResult{}, ErrCallerRevoked
	}
	successor, ok := accounts[successorID]
	if !ok || successor.unavailable {
		return HandoverResult{}, ErrSuccessorIneligible
	}

	prevHash, err := lastHandoverHash(ctx, tx, q.AlbumID)
	if err != nil {
		return HandoverResult{}, err
	}
	record := authority.SignedHandover{
		Handover: authority.Handover{
			AlbumID:       q.AlbumID,
			Term:          q.Term,
			PrevHash:      prevHash,
			OldToken:      q.CallerToken,
			NewToken:      q.NewToken,
			NewGeneration: uint32(generation),
			NewIKPub:      successor.ik,
			NewLKPub:      successor.lk,
			Mode:          q.Mode,
			DeleteMedia:   q.DeleteMedia,
		},
		Sig: q.Sig,
	}
	if authority.VerifyHandover(record, caller.ik) != nil {
		return HandoverResult{}, ErrHandoverSig
	}

	if _, err := tx.Exec(ctx,
		`INSERT INTO album_handovers
		 (album_id, term, prev_hash, old_token, new_token, new_generation,
		  new_ik_pub, new_lk_pub, mode, delete_media, sig, operation_id, request_hash)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)`,
		q.AlbumID, int32(q.Term), prevHash, q.CallerToken, q.NewToken, generation,
		successor.ik, successor.lk, int16(q.Mode), q.DeleteMedia, q.Sig, q.OperationID, q.hash(),
	); err != nil {
		return HandoverResult{}, err
	}
	if _, err := tx.Exec(ctx,
		`UPDATE album_members
		 SET role = CASE WHEN member_token = $2 THEN 'admin' ELSE 'member' END
		 WHERE album_id = $1 AND member_token IN ($2, $3)`,
		q.AlbumID, q.NewToken, q.CallerToken,
	); err != nil {
		return HandoverResult{}, err
	}
	if _, err := tx.Exec(ctx,
		`UPDATE albums SET admin_term = $2 WHERE id = $1`, q.AlbumID, int32(q.Term),
	); err != nil {
		return HandoverResult{}, err
	}

	out := HandoverResult{
		Term: q.Term, Mode: q.Mode, OldToken: q.CallerToken, NewToken: q.NewToken, Committed: true,
	}
	if q.Mode == authority.ModeLeave {
		media := KeepMedia
		if q.DeleteMedia {
			media = DeleteMedia
		}
		rev, err := r.revokeLocked(ctx, tx, q.AlbumID, q.CallerToken, media)
		if err != nil {
			return HandoverResult{}, err
		}
		out.Media = rev.Media
	}
	return out, tx.Commit(ctx)
}

func priorHandover(ctx context.Context, tx pgx.Tx, q HandoverRequest) (HandoverResult, bool, error) {
	var out HandoverResult
	var term int32
	var mode int16
	var hash []byte
	err := tx.QueryRow(ctx,
		`SELECT term, mode, old_token, new_token, request_hash
		 FROM album_handovers WHERE operation_id = $1`, q.OperationID,
	).Scan(&term, &mode, &out.OldToken, &out.NewToken, &hash)
	if errors.Is(err, pgx.ErrNoRows) {
		return out, false, nil
	}
	if err != nil {
		return out, false, err
	}
	if !bytes.Equal(hash, q.hash()) {
		return out, true, ErrHandoverReused
	}
	out.Term, out.Mode = uint32(term), byte(mode)
	return out, true, nil
}

func lastHandoverHash(ctx context.Context, tx pgx.Tx, albumID uuid.UUID) ([]byte, error) {
	last := authority.SignedHandover{Handover: authority.Handover{AlbumID: albumID}}
	var term, generation int32
	var mode int16
	err := tx.QueryRow(ctx,
		`SELECT term, prev_hash, old_token, new_token, new_generation,
		        new_ik_pub, new_lk_pub, mode, delete_media, sig
		 FROM album_handovers WHERE album_id = $1 ORDER BY term DESC LIMIT 1`,
		albumID,
	).Scan(&term, &last.PrevHash, &last.OldToken, &last.NewToken, &generation,
		&last.NewIKPub, &last.NewLKPub, &mode, &last.DeleteMedia, &last.Sig)
	if errors.Is(err, pgx.ErrNoRows) {
		return authority.ZeroHash, nil
	}
	if err != nil {
		return nil, err
	}
	last.Term, last.NewGeneration, last.Mode = uint32(term), uint32(generation), byte(mode)
	return authority.HandoverHash(authority.HandoverMsg(last.Handover), last.Sig), nil
}

// The operation id is a secret only the original caller holds, which is what
// lets them ask after leaving has ended their membership
func (r *AlbumRepository) HandoverOutcome(ctx context.Context, operationID uuid.UUID) (uuid.UUID, byte, error) {
	var albumID uuid.UUID
	var mode int16
	err := r.DB.QueryRow(ctx,
		`SELECT album_id, mode FROM album_handovers WHERE operation_id = $1`, operationID,
	).Scan(&albumID, &mode)
	if errors.Is(err, pgx.ErrNoRows) {
		return uuid.Nil, 0, ErrHandoverNotFound
	}
	return albumID, byte(mode), err
}
