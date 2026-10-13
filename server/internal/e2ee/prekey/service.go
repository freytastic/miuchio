package prekey

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"time"

	"github.com/freytastic/miuchio/internal/apierr"
	"github.com/freytastic/miuchio/internal/crypto"
	"github.com/freytastic/miuchio/internal/model"
	"github.com/google/uuid"
)

// tsSkewWindow caps |now - claimed_ts| for both bootstrap and rotate
const tsSkewWindow = 5 * time.Minute

// opkBatchMax bounds POST /users/me/opks
const opkBatchMax = 100

// opkLowThreshold triggers e2ee.opk_low once a fetch drops the target's
// unconsumed count below it
const opkLowThreshold = 5

// store is the repo surface the service needs
type store interface {
	IdentityByID(ctx context.Context, userID uuid.UUID) (*Identity, error)
	PublishOrRefreshIdentity(ctx context.Context, userID uuid.UUID, ikPub, lkPub, spkPub, spkSig []byte, spkTs int64) error
	RotateSPK(ctx context.Context, userID uuid.UUID, spkPub, spkSig []byte, spkTs int64) error
	CreateBatchAtomic(ctx context.Context, opks []model.OneTimePrekey) error
	PopRandom(ctx context.Context, userID uuid.UUID) (*model.OneTimePrekey, error)
	Count(ctx context.Context, userID uuid.UUID) (int, error)
}

// Service validates and verifies the prekey endpoints. A nil notifier drops
// opk_low fanouts
type Service struct {
	repo store
	now  func() time.Time
}

func NewService(repo store) *Service {
	return &Service{repo: repo, now: time.Now}
}

// SetClock pins the clock for skew tests
func (s *Service) SetClock(fn func() time.Time) { s.now = fn }

type UpsertIdentityInput struct {
	IKPub  []byte
	LKPub  []byte
	SPKPub []byte
	SPKSig []byte
	SPKTs  int64
}

// UpsertIdentity checks length, then ts skew, then signature, then state
func (s *Service) UpsertIdentity(ctx context.Context, userID uuid.UUID, in UpsertIdentityInput) error {
	if len(in.IKPub) != ed25519.PublicKeySize ||
		len(in.LKPub) != 32 ||
		len(in.SPKPub) != 32 {
		return apierr.Validation("ik_pub/lk_pub/spk_pub must be 32 bytes")
	}
	if len(in.SPKSig) != ed25519.SignatureSize {
		return apierr.Validation("spk_sig must be 64 bytes")
	}
	if !withinSkew(s.now(), in.SPKTs, tsSkewWindow) {
		return apierr.TsSkew("spk_ts outside acceptable skew window")
	}
	msg := spkSelfMsg(in.SPKPub, in.SPKTs)
	if err := crypto.VerifyEd25519(ed25519.PublicKey(in.IKPub), msg, in.SPKSig); err != nil {
		return apierr.SigInvalid("spk_sig verification failed").WithCause(err)
	}
	// The repository atomically distinguishes identical retries from conflicts
	err := s.repo.PublishOrRefreshIdentity(ctx, userID, in.IKPub, in.LKPub, in.SPKPub, in.SPKSig, in.SPKTs)
	if errors.Is(err, ErrIdentityConflict) {
		return apierr.IdentityAlreadySet("identity already published; rotate via POST /users/me/spk")
	}
	return err
}

type RotateSPKInput struct {
	SPKPub      []byte
	SPKSig      []byte
	SPKTs       int64
	RotationSig []byte
}

// RotateSPK checks lengths, ts skew, state, spk_sig, rotation_sig, then
// monotonic ts. The audit row commits in the same transaction
func (s *Service) RotateSPK(ctx context.Context, userID uuid.UUID, in RotateSPKInput) error {
	if len(in.SPKPub) != 32 {
		return apierr.Validation("spk_pub must be 32 bytes")
	}
	if len(in.SPKSig) != ed25519.SignatureSize {
		return apierr.Validation("spk_sig must be 64 bytes")
	}
	if len(in.RotationSig) != ed25519.SignatureSize {
		return apierr.Validation("rotation_sig must be 64 bytes")
	}
	if !withinSkew(s.now(), in.SPKTs, tsSkewWindow) {
		return apierr.TsSkew("spk_ts outside acceptable skew window")
	}
	cur, err := s.repo.IdentityByID(ctx, userID)
	if err != nil {
		return err
	}
	if len(cur.IKPub) == 0 {
		return apierr.IdentityNotSet("publish identity via PUT /users/me/keys before rotating")
	}
	ikPub := ed25519.PublicKey(cur.IKPub)
	if err := crypto.VerifyEd25519(ikPub, spkSelfMsg(in.SPKPub, in.SPKTs), in.SPKSig); err != nil {
		return apierr.SigInvalid("spk_sig verification failed").WithCause(err)
	}
	if err := crypto.VerifyEd25519(ikPub, RotationMsg(in.SPKPub, in.SPKTs), in.RotationSig); err != nil {
		return apierr.SigInvalid("rotation_sig verification failed").WithCause(err)
	}
	// Fast fail; the repository repeats this check under the row lock
	if cur.SPKTs != nil && in.SPKTs <= *cur.SPKTs {
		return apierr.TsNotMonotonic("spk_ts must be strictly greater than current spk_ts")
	}
	err = s.repo.RotateSPK(ctx, userID, in.SPKPub, in.SPKSig, in.SPKTs)
	if errors.Is(err, ErrTsNotMonotonic) {
		return apierr.TsNotMonotonic("spk_ts must be strictly greater than current spk_ts")
	}
	return err
}

// OwnKeys does not pop an OPK
func (s *Service) OwnKeys(ctx context.Context, userID uuid.UUID) (*Identity, error) {
	return s.repo.IdentityByID(ctx, userID)
}

type OPKUpload struct {
	Idx    int
	KeyPub []byte
}

type ReplenishOPKsInput struct {
	OPKs         []OPKUpload
	ReplenishSig []byte
}

func (s *Service) ReplenishOPKs(ctx context.Context, userID uuid.UUID, in ReplenishOPKsInput) error {
	if len(in.OPKs) == 0 {
		return apierr.Validation("opks must be a non-empty array")
	}
	if len(in.OPKs) > opkBatchMax {
		return apierr.Validation("opks batch exceeds 100")
	}
	if len(in.ReplenishSig) != ed25519.SignatureSize {
		return apierr.Validation("replenish_sig must be 64 bytes")
	}
	for _, o := range in.OPKs {
		if o.Idx < 0 {
			return apierr.Validation("opks[].idx must be >= 0")
		}
		if len(o.KeyPub) != 32 {
			return apierr.Validation("opks[].key_pub must be 32 bytes")
		}
	}
	cur, err := s.repo.IdentityByID(ctx, userID)
	if err != nil {
		return err
	}
	if len(cur.IKPub) == 0 {
		return apierr.IdentityNotSet("publish identity via PUT /users/me/keys before uploading OPKs")
	}
	pubs := make([][]byte, len(in.OPKs))
	for i, o := range in.OPKs {
		pubs[i] = o.KeyPub
	}
	if err := crypto.VerifyEd25519(ed25519.PublicKey(cur.IKPub), ReplenishMsg(pubs), in.ReplenishSig); err != nil {
		return apierr.SigInvalid("replenish_sig verification failed").WithCause(err)
	}
	rows := make([]model.OneTimePrekey, len(in.OPKs))
	for i, o := range in.OPKs {
		rows[i] = model.OneTimePrekey{ID: uuid.New(), UserID: userID, OPKIdx: o.Idx, KeyPub: o.KeyPub}
	}
	if err := s.repo.CreateBatchAtomic(ctx, rows); err != nil {
		if errors.Is(err, ErrOPKIndexTaken) {
			return apierr.OPKIndexTaken("one or more opk_idx values already exist for this user")
		}
		return err
	}
	return nil
}

func (s *Service) GetOPKCount(ctx context.Context, userID uuid.UUID) (int, error) {
	return s.repo.Count(ctx, userID)
}

type PrekeyBundle struct {
	UserID  uuid.UUID
	IKPub   []byte
	LKPub   []byte
	SPKPub  []byte
	SPKSig  []byte
	SPKTs   int64
	OPK     *OPKUpload
	OPKLeft int // -1 when no OPK was popped
}

// GetPrekeyBundle pops one OPK. The caller emits e2ee.opk_low when OPKLeft
// drops below the threshold
func (s *Service) GetPrekeyBundle(ctx context.Context, targetID uuid.UUID) (*PrekeyBundle, error) {
	id, err := s.repo.IdentityByID(ctx, targetID)
	if err != nil {
		return nil, err
	}
	if len(id.IKPub) == 0 || len(id.SPKPub) == 0 {
		return nil, apierr.IdentityNotSet("target has not published an identity")
	}
	out := &PrekeyBundle{
		UserID:  targetID,
		IKPub:   id.IKPub,
		LKPub:   id.LKPub,
		SPKPub:  id.SPKPub,
		SPKSig:  id.SPKSig,
		OPKLeft: -1,
	}
	if id.SPKTs != nil {
		out.SPKTs = *id.SPKTs
	}
	opk, err := s.repo.PopRandom(ctx, targetID)
	if err != nil {
		return nil, err
	}
	if opk != nil {
		out.OPK = &OPKUpload{Idx: opk.OPKIdx, KeyPub: opk.KeyPub}
		n, err := s.repo.Count(ctx, targetID)
		if err != nil {
			return nil, err
		}
		out.OPKLeft = n
	}
	return out, nil
}

func OPKLowThreshold() int { return opkLowThreshold }

// spkSelfMsg is spk_pub ‖ u64_be(spk_ts) with no salt, rotation_sig carries
// its own domain separator
func spkSelfMsg(spkPub []byte, spkTs int64) []byte {
	out := make([]byte, 0, 32+8)
	out = append(out, spkPub...)
	var ts [8]byte
	binary.BigEndian.PutUint64(ts[:], uint64(spkTs))
	return append(out, ts[:]...)
}

// RotationMsg is "rotate-spk-v1" ‖ spk_pub ‖ u64_be(spk_ts), shared with the
// KAT generator
func RotationMsg(spkPub []byte, spkTs int64) []byte {
	out := make([]byte, 0, len(crypto.SaltSpkRotate)+32+8)
	out = append(out, crypto.SaltSpkRotate...)
	out = append(out, spkPub...)
	var ts [8]byte
	binary.BigEndian.PutUint64(ts[:], uint64(spkTs))
	return append(out, ts[:]...)
}

// ReplenishMsg is "opk-batch-v1" ‖ u32_be(len) ‖ SHA256(raw 32B pubs in order)
func ReplenishMsg(opkPubs [][]byte) []byte {
	h := sha256.New()
	for _, p := range opkPubs {
		h.Write(p)
	}
	digest := h.Sum(nil)
	prefix := []byte("opk-batch-v1")
	out := make([]byte, 0, len(prefix)+4+len(digest))
	out = append(out, prefix...)
	var n [4]byte
	binary.BigEndian.PutUint32(n[:], uint32(len(opkPubs)))
	out = append(out, n[:]...)
	return append(out, digest...)
}

func withinSkew(now time.Time, ts int64, window time.Duration) bool {
	delta := now.Unix() - ts
	if delta < 0 {
		delta = -delta
	}
	return time.Duration(delta)*time.Second <= window
}
