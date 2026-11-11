package invite

import (
	"bytes"
	"context"
	"errors"
	"fmt"

	"github.com/freytastic/miuchio/internal/e2ee/authority"
	"github.com/freytastic/miuchio/internal/repository"
	"github.com/freytastic/miuchio/internal/userlink"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ErrIKNotFound is treated as a signature failure by the service
var ErrIKNotFound = errors.New("invite: member has no IK on file")

var (
	ErrSenderRevoked   = errors.New("invite: sender is no longer an active member")
	ErrSenderNotAdmin  = errors.New("invite: sender is not the album admin")
	ErrEpochMoved      = errors.New("invite: envelopes no longer reach the current epoch")
	ErrPendingRotation = errors.New("invite: album owes a rotation")
	ErrTargetDeleting  = errors.New("invite: target account is being deleted")
	ErrBlocked         = errors.New("invite: one of the two has blocked the other")
	ErrNoteInvalid     = errors.New("invite: a note does not match the album's locked state")
	ErrNoteSig         = errors.New("invite: a note is not signed by the admin")
	ErrNotesMissing    = errors.New("invite: an active member has no note from this admin")
	ErrReceiptStale    = errors.New("invite: receipt does not match the active membership")
)

// The membership this account must be invited as. A returning member keeps
// their token and moves to the next generation
type TokenMismatchError struct {
	Token      []byte
	Generation int
}

func (e *TokenMismatchError) Error() string {
	return fmt.Sprintf("invite: note must name generation %d of the existing token", e.Generation)
}

type Repo struct {
	db     *pgxpool.Pool
	linker *userlink.Hasher
	users  *repository.UserRepository
}

func NewRepo(db *pgxpool.Pool, linker *userlink.Hasher, users *repository.UserRepository) *Repo {
	if linker == nil || users == nil {
		panic("invite.NewRepo: linker and users are required")
	}
	return &Repo{db: db, linker: linker, users: users}
}

func (r *Repo) FindUserIDByMiuchioID(ctx context.Context, miuchioID string) (uuid.UUID, error) {
	return r.users.FindUserIDByMiuchioID(ctx, miuchioID)
}

func (r *Repo) CurrentEpoch(ctx context.Context, albumID uuid.UUID) (int, error) {
	var epoch int
	err := r.db.QueryRow(ctx,
		`SELECT COALESCE(MAX(epoch), -1) FROM album_epochs WHERE album_id = $1`,
		albumID,
	).Scan(&epoch)
	if err != nil {
		return 0, err
	}
	return epoch, nil
}

// Opens the sealed user link before loading its identity key
func (r *Repo) IKByMemberToken(ctx context.Context, memberToken []byte) ([]byte, error) {
	var sealed []byte
	err := r.db.QueryRow(ctx,
		`SELECT user_id_enc FROM album_member_identities WHERE member_token = $1`,
		memberToken,
	).Scan(&sealed)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrIKNotFound
	}
	if err != nil {
		return nil, err
	}
	userID, err := r.linker.Open(sealed, memberToken)
	if err != nil {
		return nil, ErrIKNotFound
	}
	var ik []byte
	err = r.db.QueryRow(ctx, `SELECT ik_pub FROM users WHERE id = $1`, userID).Scan(&ik)
	if errors.Is(err, pgx.ErrNoRows) || len(ik) == 0 {
		return nil, ErrIKNotFound
	}
	if err != nil {
		return nil, err
	}
	return ik, nil
}

// Opens each active member link and skips invalid seals
func (r *Repo) ActiveMemberUserIDs(ctx context.Context, albumID uuid.UUID) ([]uuid.UUID, error) {
	rows, err := r.db.Query(ctx,
		`SELECT amid.member_token, amid.user_id_enc
		 FROM album_members am
		 JOIN album_member_identities amid ON amid.member_token = am.member_token
		 WHERE am.album_id = $1 AND am.revoked_at IS NULL`,
		albumID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []uuid.UUID
	for rows.Next() {
		var tok, sealed []byte
		if err := rows.Scan(&tok, &sealed); err != nil {
			return nil, err
		}
		u, err := r.linker.Open(sealed, tok)
		if err != nil {
			continue
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

type accountKeys struct{ ik, lk []byte }

type lockedInvite struct {
	senderIK []byte
	target   accountKeys
}

// Rechecks authority and epoch under the lock shared with revoke and rotation
func (r *Repo) recheckUnderLock(ctx context.Context, tx pgx.Tx, in DeliverMemberInput) (lockedInvite, error) {
	var out lockedInvite
	err := r.recheck(ctx, tx, in, &out)
	return out, err
}

func (r *Repo) recheck(ctx context.Context, tx pgx.Tx, in DeliverMemberInput, out *lockedInvite) error {
	var role string
	var revoked bool
	var sealed []byte
	err := tx.QueryRow(ctx,
		`SELECT am.role, am.revoked_at IS NOT NULL, ami.user_id_enc
		 FROM album_members am
		 JOIN album_member_identities ami ON ami.member_token = am.member_token
		 WHERE am.album_id = $1 AND am.member_token = $2`,
		in.AlbumID, in.SenderToken,
	).Scan(&role, &revoked, &sealed)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && revoked) {
		return ErrSenderRevoked
	}
	if err != nil {
		return err
	}
	if role != "admin" {
		return ErrSenderNotAdmin
	}
	sender, err := r.linker.Open(sealed, in.SenderToken)
	if err != nil {
		return ErrSenderRevoked
	}

	// FOR SHARE waits out an account deletion being accepted, so neither side
	// can join an album the deletion job has already enumerated
	rows, err := tx.Query(ctx,
		`SELECT id, deleting_at IS NOT NULL OR suspended_at IS NOT NULL, ik_pub, lk_pub FROM users
		 WHERE id = ANY($1) ORDER BY id FOR SHARE`,
		[]uuid.UUID{sender, in.UserID},
	)
	if err != nil {
		return err
	}
	deleting := map[uuid.UUID]bool{}
	for rows.Next() {
		var id uuid.UUID
		var d bool
		var keys accountKeys
		if err := rows.Scan(&id, &d, &keys.ik, &keys.lk); err != nil {
			rows.Close()
			return err
		}
		deleting[id] = d
		if id == sender {
			out.senderIK = keys.ik
		}
		if id == in.UserID {
			out.target = keys
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	if d, ok := deleting[sender]; !ok || d {
		return ErrSenderRevoked
	}
	if d, ok := deleting[in.UserID]; !ok || d {
		return ErrTargetDeleting
	}

	pair := r.linker.BlockPair(sender, in.UserID)
	if err := repository.LockBlockPair(ctx, tx, pair); err != nil {
		return err
	}
	blocked, err := repository.PairBlocked(ctx, tx, pair)
	if err != nil {
		return err
	}
	if blocked {
		return ErrBlocked
	}

	var current int
	if err := tx.QueryRow(ctx,
		`SELECT COALESCE(MAX(epoch), -1) FROM album_epochs WHERE album_id = $1`,
		in.AlbumID,
	).Scan(&current); err != nil {
		return err
	}
	if len(in.Envelopes) == 0 || in.Envelopes[len(in.Envelopes)-1].Epoch != current {
		return ErrEpochMoved
	}

	var owed bool
	if err := tx.QueryRow(ctx,
		`SELECT `+repository.RotationRequiredExpr("$1"), in.AlbumID,
	).Scan(&owed); err != nil {
		return err
	}
	if owed {
		return ErrPendingRotation
	}
	return nil
}

// Atomically creates or reactivates membership, stores wraps and consumes the OPK
func (r *Repo) DeliverMember(ctx context.Context, in DeliverMemberInput) ([]byte, error) {
	tx, err := r.db.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	// Serializes joins so concurrent invites cannot exceed the member cap
	var locked uuid.UUID
	if err := tx.QueryRow(ctx, `SELECT id FROM albums WHERE id = $1 FOR UPDATE`, in.AlbumID).Scan(&locked); err != nil {
		return nil, err
	}
	invite, err := r.recheckUnderLock(ctx, tx, in)
	if err != nil {
		return nil, err
	}

	userHandle := r.linker.Hash(in.UserID)

	// Reactivation reuses the tombstoned token because signed history still references it
	var token []byte
	var revoked bool
	var joins int
	err = tx.QueryRow(ctx,
		`SELECT ami.member_token, am.revoked_at IS NOT NULL, am.joins
		 FROM album_member_identities ami
		 JOIN album_members am ON am.album_id = ami.album_id AND am.member_token = ami.member_token
		 WHERE ami.user_handle = $1 AND ami.album_id = $2`,
		userHandle, in.AlbumID,
	).Scan(&token, &revoked, &joins)
	reactivate := err == nil
	if err != nil && err != pgx.ErrNoRows {
		return nil, err
	}
	if reactivate && !revoked {
		return nil, ErrAlreadyMember
	}

	// The admin signed a note over the token before this ran, so a fresh
	// member takes the proposed one and a mismatch is handed back to re sign
	generation := 1
	if reactivate {
		generation = joins + 1
	} else {
		token = in.Note.MemberToken
	}
	if !bytes.Equal(in.Note.MemberToken, token) || int(in.Note.Generation) != generation {
		return nil, &TokenMismatchError{Token: token, Generation: generation}
	}

	if !reactivate {
		sealed, err := r.linker.Seal(in.UserID, token)
		if err != nil {
			return nil, err
		}
		if _, err := tx.Exec(ctx,
			`INSERT INTO album_member_identities (member_token, user_handle, user_id_enc, album_id) VALUES ($1, $2, $3, $4)`,
			token, userHandle, sealed, in.AlbumID,
		); err != nil {
			var pgErr *pgconn.PgError
			if errors.As(err, &pgErr) && pgErr.Code == "23505" {
				return nil, ErrAlreadyMember
			}
			return nil, err
		}
	}

	// Count after duplicate detection so an active member returns ErrAlreadyMember
	var active int
	if err := tx.QueryRow(ctx,
		`SELECT count(*) FROM album_members WHERE album_id = $1 AND revoked_at IS NULL`,
		in.AlbumID,
	).Scan(&active); err != nil {
		return nil, err
	}
	if active >= MaxAlbumMembers {
		return nil, ErrAlbumFull
	}

	if reactivate {
		// The old encrypted name was sealed under an epoch the returning member
		// no longer holds
		if _, err := tx.Exec(ctx,
			`UPDATE album_members SET revoked_at = NULL, role = 'member', name_ct = NULL, joins = joins + 1
			 WHERE album_id = $1 AND member_token = $2`,
			in.AlbumID, token,
		); err != nil {
			return nil, err
		}
	} else {
		if _, err := tx.Exec(ctx,
			`INSERT INTO album_members (album_id, member_token, role) VALUES ($1, $2, 'member')`,
			in.AlbumID, token,
		); err != nil {
			return nil, err
		}
	}

	for _, e := range in.Envelopes {
		var opk any
		if in.OPKIdxUsed != nil {
			opk = *in.OPKIdxUsed
		}
		// Reactivated members replace wraps tied to their reused token
		if _, err := tx.Exec(ctx,
			`INSERT INTO album_epoch_wraps
			 (album_id, epoch, recipient_token, ek_pub, opk_idx_used,
			  wrap_nonce, wrap_tag_ct, sender_token, sender_sig, sender_generation)
			 SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9, s.joins
			 FROM album_members s WHERE s.album_id = $1 AND s.member_token = $8
			 ON CONFLICT (album_id, epoch, recipient_token) DO UPDATE SET
			   ek_pub = EXCLUDED.ek_pub, opk_idx_used = EXCLUDED.opk_idx_used,
			   wrap_nonce = EXCLUDED.wrap_nonce, wrap_tag_ct = EXCLUDED.wrap_tag_ct,
			   sender_token = EXCLUDED.sender_token, sender_sig = EXCLUDED.sender_sig,
			   sender_generation = EXCLUDED.sender_generation`,
			in.AlbumID, e.Epoch, token, in.EKPub, opk,
			e.WrapNonce, e.WrapTagCT, in.SenderToken, e.SenderSig,
		); err != nil {
			return nil, err
		}
	}

	if err := r.storeNotes(ctx, tx, in, invite); err != nil {
		return nil, err
	}

	if in.OPKIdxUsed != nil {
		if _, err := tx.Exec(ctx,
			`UPDATE one_time_prekeys SET consumed = TRUE WHERE user_id = $1 AND opk_idx = $2`,
			in.UserID, *in.OPKIdxUsed,
		); err != nil {
			return nil, err
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return token, nil
}

// Stores the newcomer's note and any reissued for current members, all in
// the transaction that activates the membership. Afterwards every active
// member holds a note from the current admin term, which is what lets a
// newcomer trust the roster through their inviter alone
func (r *Repo) storeNotes(ctx context.Context, tx pgx.Tx, in DeliverMemberInput, locked lockedInvite) error {
	var term int
	if err := tx.QueryRow(ctx,
		`SELECT admin_term FROM albums WHERE id = $1`, in.AlbumID,
	).Scan(&term); err != nil {
		return err
	}
	check := func(n authority.SignedNote, keys accountKeys) error {
		if n.AlbumID != in.AlbumID || int(n.IssuerTerm) != term ||
			!bytes.Equal(n.IKPub, keys.ik) || !bytes.Equal(n.LKPub, keys.lk) {
			return ErrNoteInvalid
		}
		if authority.VerifyNote(n, locked.senderIK) != nil {
			return ErrNoteSig
		}
		return authority.InsertNote(ctx, tx, n)
	}
	if err := check(in.Note, locked.target); err != nil {
		return err
	}
	for _, n := range in.ExtraNotes {
		keys, err := r.activeMemberKeys(ctx, tx, in.AlbumID, n.MemberToken, int(n.Generation))
		if err != nil {
			return err
		}
		if err := check(n, keys); err != nil {
			return err
		}
	}
	var missing bool
	if err := tx.QueryRow(ctx,
		`SELECT EXISTS (
		   SELECT 1 FROM album_members m
		   WHERE m.album_id = $1 AND m.revoked_at IS NULL
		     AND NOT EXISTS (
		       SELECT 1 FROM member_notes n
		       WHERE n.album_id = m.album_id AND n.member_token = m.member_token
		         AND n.generation = m.joins AND n.issuer_term = $2))`,
		in.AlbumID, term,
	).Scan(&missing); err != nil {
		return err
	}
	if missing {
		return ErrNotesMissing
	}
	return nil
}

// The published keys of an active member at exactly this generation
func (r *Repo) activeMemberKeys(ctx context.Context, tx pgx.Tx, albumID uuid.UUID, token []byte, generation int) (accountKeys, error) {
	var sealed []byte
	err := tx.QueryRow(ctx,
		`SELECT ami.user_id_enc
		 FROM album_members am
		 JOIN album_member_identities ami ON ami.member_token = am.member_token
		 WHERE am.album_id = $1 AND am.member_token = $2
		   AND am.revoked_at IS NULL AND am.joins = $3`,
		albumID, token, generation,
	).Scan(&sealed)
	if errors.Is(err, pgx.ErrNoRows) {
		return accountKeys{}, ErrNoteInvalid
	}
	if err != nil {
		return accountKeys{}, err
	}
	userID, err := r.linker.Open(sealed, token)
	if err != nil {
		return accountKeys{}, ErrNoteInvalid
	}
	var keys accountKeys
	err = tx.QueryRow(ctx,
		`SELECT ik_pub, lk_pub FROM users WHERE id = $1`, userID,
	).Scan(&keys.ik, &keys.lk)
	if errors.Is(err, pgx.ErrNoRows) {
		return accountKeys{}, ErrNoteInvalid
	}
	return keys, err
}

// Records that the caller installed the keys of their active membership. The
// receipt signs the invite's one time value, so matching it against the
// stored wrap refuses a late receipt from an earlier membership
func (r *Repo) AckJoin(ctx context.Context, albumID uuid.UUID, memberToken []byte, epoch int, ekPub []byte) error {
	tx, err := r.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var locked uuid.UUID
	if err := tx.QueryRow(ctx, `SELECT id FROM albums WHERE id = $1 FOR UPDATE`, albumID).Scan(&locked); err != nil {
		return err
	}
	var stored []byte
	err = tx.QueryRow(ctx,
		`SELECT w.ek_pub FROM album_epoch_wraps w
		 JOIN album_members m ON m.album_id = w.album_id AND m.member_token = w.recipient_token
		 WHERE w.album_id = $1 AND w.epoch = $2 AND w.recipient_token = $3
		   AND m.revoked_at IS NULL`,
		albumID, epoch, memberToken,
	).Scan(&stored)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !bytes.Equal(stored, ekPub)) {
		return ErrReceiptStale
	}
	if err != nil {
		return err
	}
	if _, err := tx.Exec(ctx,
		`UPDATE album_members SET acked_joins = joins
		 WHERE album_id = $1 AND member_token = $2`,
		albumID, memberToken,
	); err != nil {
		return err
	}
	// GREATEST prevents stale receipts from lowering the acknowledged epoch
	if _, err := tx.Exec(ctx,
		`UPDATE album_member_identities
		 SET last_received_epoch = GREATEST(COALESCE(last_received_epoch, -1), $2),
		     last_received_at = now()
		 WHERE member_token = $1`,
		memberToken, epoch,
	); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
