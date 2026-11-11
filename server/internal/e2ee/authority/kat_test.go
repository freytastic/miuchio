package authority

import (
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/google/uuid"
)

// Pins both record layouts against the fixture the Dart side also reads
func TestAuthorityKAT(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "test_vectors", "authority_kat.json"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var k struct {
		Notes []struct {
			Name           string `json:"name"`
			SignerSeedHex  string `json:"signer_seed_hex"`
			AlbumIDHex     string `json:"album_id_hex"`
			MemberTokenHex string `json:"member_token_hex"`
			Generation     uint32 `json:"generation"`
			IKPubHex       string `json:"ik_pub_hex"`
			LKPubHex       string `json:"lk_pub_hex"`
			IssuerTerm     uint32 `json:"issuer_term"`
			ExpectedMsgHex string `json:"expected_msg_hex"`
			ExpectedSigHex string `json:"expected_sig_hex"`
		} `json:"notes"`
		Handovers []struct {
			Name            string `json:"name"`
			SignerSeedHex   string `json:"signer_seed_hex"`
			AlbumIDHex      string `json:"album_id_hex"`
			Term            uint32 `json:"term"`
			PrevHashHex     string `json:"prev_hash_hex"`
			OldTokenHex     string `json:"old_token_hex"`
			NewTokenHex     string `json:"new_token_hex"`
			NewGeneration   uint32 `json:"new_generation"`
			NewIKPubHex     string `json:"new_ik_pub_hex"`
			NewLKPubHex     string `json:"new_lk_pub_hex"`
			Mode            byte   `json:"mode"`
			DeleteMedia     bool   `json:"delete_media"`
			ExpectedMsgHex  string `json:"expected_msg_hex"`
			ExpectedSigHex  string `json:"expected_sig_hex"`
			ExpectedHashHex string `json:"expected_hash_hex"`
		} `json:"handovers"`
	}
	if err := json.Unmarshal(raw, &k); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(k.Notes) == 0 || len(k.Handovers) == 0 {
		t.Fatal("fixture has no vectors")
	}
	for _, v := range k.Notes {
		t.Run(v.Name, func(t *testing.T) {
			msg := NoteMsg(Note{
				AlbumID:     mustUUID(t, v.AlbumIDHex),
				MemberToken: mustHex(t, v.MemberTokenHex),
				Generation:  v.Generation,
				IKPub:       mustHex(t, v.IKPubHex),
				LKPub:       mustHex(t, v.LKPubHex),
				IssuerTerm:  v.IssuerTerm,
			})
			checkSigned(t, msg, v.SignerSeedHex, v.ExpectedMsgHex, v.ExpectedSigHex)
		})
	}
	for _, v := range k.Handovers {
		t.Run(v.Name, func(t *testing.T) {
			msg := HandoverMsg(Handover{
				AlbumID:       mustUUID(t, v.AlbumIDHex),
				Term:          v.Term,
				PrevHash:      mustHex(t, v.PrevHashHex),
				OldToken:      mustHex(t, v.OldTokenHex),
				NewToken:      mustHex(t, v.NewTokenHex),
				NewGeneration: v.NewGeneration,
				NewIKPub:      mustHex(t, v.NewIKPubHex),
				NewLKPub:      mustHex(t, v.NewLKPubHex),
				Mode:          v.Mode,
				DeleteMedia:   v.DeleteMedia,
			})
			sig := checkSigned(t, msg, v.SignerSeedHex, v.ExpectedMsgHex, v.ExpectedSigHex)
			if got := hex.EncodeToString(HandoverHash(msg, sig)); got != v.ExpectedHashHex {
				t.Fatalf("hash = %s, want %s", got, v.ExpectedHashHex)
			}
		})
	}
}

func checkSigned(t *testing.T, msg []byte, seedHex, wantMsg, wantSig string) []byte {
	t.Helper()
	if got := hex.EncodeToString(msg); got != wantMsg {
		t.Fatalf("msg = %s, want %s", got, wantMsg)
	}
	sig := ed25519.Sign(ed25519.NewKeyFromSeed(mustHex(t, seedHex)), msg)
	if got := hex.EncodeToString(sig); got != wantSig {
		t.Fatalf("sig = %s, want %s", got, wantSig)
	}
	return sig
}

func mustUUID(t *testing.T, s string) uuid.UUID {
	t.Helper()
	id, err := uuid.FromBytes(mustHex(t, s))
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatalf("hex %q: %v", s, err)
	}
	return b
}
