// genauthoritykat generates test_vectors/authority_kat.json, shared by
// internal/e2ee/authority/kat_test.go and client/test/e2ee/authority_kat_test.dart.
// Output is byte stable. Run once into the JSON, then never edit the bytes:

// go run ./cmd/genauthoritykat > test_vectors/authority_kat.json
package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"

	"github.com/freytastic/miuchio/internal/e2ee/authority"
	"github.com/google/uuid"
)

type noteVector struct {
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
}

type handoverVector struct {
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
}

type kat struct {
	Category  string           `json:"category"`
	Notes     []noteVector     `json:"notes"`
	Handovers []handoverVector `json:"handovers"`
}

func rep(b byte, n int) []byte { return bytes.Repeat([]byte{b}, n) }

func main() {
	out := kat{Category: "authority"}

	notes := []struct {
		name       string
		seed, b    byte
		generation uint32
		term       uint32
	}{
		{"note creator self signed", 0xA1, 0x10, 1, 0},
		{"note member term 0", 0xA2, 0x20, 1, 0},
		{"note rejoin generation 3 term 7", 0xA3, 0x30, 3, 7},
	}
	for _, s := range notes {
		albumBytes := rep(s.b, 16)
		albumID, err := uuid.FromBytes(albumBytes)
		if err != nil {
			fail(err)
		}
		n := authority.Note{
			AlbumID:     albumID,
			MemberToken: rep(s.b+1, 32),
			Generation:  s.generation,
			IKPub:       rep(s.b+2, 32),
			LKPub:       rep(s.b+3, 32),
			IssuerTerm:  s.term,
		}
		seed := rep(s.seed, 32)
		msg := authority.NoteMsg(n)
		sig := ed25519.Sign(ed25519.NewKeyFromSeed(seed), msg)
		out.Notes = append(out.Notes, noteVector{
			Name:           s.name,
			SignerSeedHex:  hex.EncodeToString(seed),
			AlbumIDHex:     hex.EncodeToString(albumBytes),
			MemberTokenHex: hex.EncodeToString(n.MemberToken),
			Generation:     n.Generation,
			IKPubHex:       hex.EncodeToString(n.IKPub),
			LKPubHex:       hex.EncodeToString(n.LKPub),
			IssuerTerm:     n.IssuerTerm,
			ExpectedMsgHex: hex.EncodeToString(msg),
			ExpectedSigHex: hex.EncodeToString(sig),
		})
	}

	handovers := []struct {
		name        string
		seed, b     byte
		term        uint32
		generation  uint32
		mode        byte
		deleteMedia bool
	}{
		{"handover first stay", 0xB1, 0x40, 1, 1, authority.ModeStay, false},
		{"handover chained leave keeps photos", 0xB2, 0x50, 2, 1, authority.ModeLeave, false},
		{"handover chained leave deletes photos", 0xB3, 0x60, 9, 4, authority.ModeLeave, true},
	}
	prev := authority.ZeroHash
	for _, s := range handovers {
		albumBytes := rep(s.b, 16)
		albumID, err := uuid.FromBytes(albumBytes)
		if err != nil {
			fail(err)
		}
		h := authority.Handover{
			AlbumID:       albumID,
			Term:          s.term,
			PrevHash:      prev,
			OldToken:      rep(s.b+1, 32),
			NewToken:      rep(s.b+2, 32),
			NewGeneration: s.generation,
			NewIKPub:      rep(s.b+3, 32),
			NewLKPub:      rep(s.b+4, 32),
			Mode:          s.mode,
			DeleteMedia:   s.deleteMedia,
		}
		seed := rep(s.seed, 32)
		msg := authority.HandoverMsg(h)
		sig := ed25519.Sign(ed25519.NewKeyFromSeed(seed), msg)
		hash := authority.HandoverHash(msg, sig)
		out.Handovers = append(out.Handovers, handoverVector{
			Name:            s.name,
			SignerSeedHex:   hex.EncodeToString(seed),
			AlbumIDHex:      hex.EncodeToString(albumBytes),
			Term:            h.Term,
			PrevHashHex:     hex.EncodeToString(h.PrevHash),
			OldTokenHex:     hex.EncodeToString(h.OldToken),
			NewTokenHex:     hex.EncodeToString(h.NewToken),
			NewGeneration:   h.NewGeneration,
			NewIKPubHex:     hex.EncodeToString(h.NewIKPub),
			NewLKPubHex:     hex.EncodeToString(h.NewLKPub),
			Mode:            h.Mode,
			DeleteMedia:     h.DeleteMedia,
			ExpectedMsgHex:  hex.EncodeToString(msg),
			ExpectedSigHex:  hex.EncodeToString(sig),
			ExpectedHashHex: hex.EncodeToString(hash),
		})
		prev = hash
	}

	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(out); err != nil {
		fail(err)
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
