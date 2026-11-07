// mod reviews reports straight from the database, so nothing about moderation
// sits on the public API. The private key never leaves this machine

//	go run ./cmd/mod keygen
//	go run ./cmd/mod list [-all]
//	go run ./cmd/mod show <report>
//	go run ./cmd/mod dismiss|inconclusive <report>
//	go run ./cmd/mod remove|suspend <report> [-unverified]
//	go run ./cmd/mod suspended
//	go run ./cmd/mod unsuspend <miuchio-id>

// DATABASE_URL, MIUCHIO_USER_LINK_KEY and the S3_* settings match the server
// MIUCHIO_MOD_KEY is the base64 private key from keygen
package main

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"text/tabwriter"
	"time"

	"github.com/freytastic/miuchio/internal/handle"
	"github.com/freytastic/miuchio/internal/repository"
	"github.com/freytastic/miuchio/internal/storage"
	"github.com/freytastic/miuchio/internal/userlink"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/nacl/box"
)

// Mirrored in client/lib/domain/safety/reporter.dart
type payload struct {
	V           int    `json:"v"`
	Kind        string `json:"kind"`
	Reason      string `json:"reason"`
	Note        string `json:"note"`
	AlbumID     string `json:"album_id"`
	MediaID     string `json:"media_id"`
	MemberToken string `json:"member_token"`
	Thumb       []byte `json:"thumb"`
	ThumbKey    []byte `json:"thumb_key"`
}

// Thumbs are VER || nonce || tag || ciphertext with AAD media_id || "thumb",
// as in client/lib/crypto/wire_format.dart
const (
	wireNonceLen = 12
	wireTagLen   = 16
	wireHeader   = 1 + wireNonceLen + wireTagLen
	maxThumb     = 512 << 10
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	cmd, args := os.Args[1], os.Args[2:]
	if cmd == "keygen" {
		keygen()
		return
	}
	ctx := context.Background()
	db, err := pgxpool.New(ctx, mustEnv("DATABASE_URL"))
	if err != nil {
		fail(err)
	}
	defer db.Close()
	reports := repository.NewReportRepository(db)

	switch cmd {
	case "list":
		fs := flag.NewFlagSet(cmd, flag.ExitOnError)
		all := fs.Bool("all", false, "include decided reports")
		_ = fs.Parse(args)
		list(ctx, reports, *all)
	case "show":
		show(ctx, reports, reportArg(args, nil))
	case "dismiss", "inconclusive":
		id := reportArg(args, nil)
		done(cmd, id, reports.Resolve(ctx, id, map[string]string{
			"dismiss": "dismissed", "inconclusive": "inconclusive"}[cmd]))
	case "remove", "suspend":
		fs := flag.NewFlagSet(cmd, flag.ExitOnError)
		unverified := fs.Bool("unverified", false, "act on a photo report whose attachment could not be checked")
		id := reportArg(args, fs)
		act(ctx, reports, cmd, id, *unverified)
	case "suspended":
		suspended(ctx, reports)
	case "unsuspend":
		if len(args) != 1 {
			usage()
		}
		id, err := handle.Normalize(args[0])
		if err != nil {
			fail(err)
		}
		done(cmd, id, reports.Unsuspend(ctx, id))
	default:
		usage()
	}
}

func keygen() {
	priv := make([]byte, curve25519.ScalarSize)
	if _, err := rand.Read(priv); err != nil {
		fail(err)
	}
	pub, err := curve25519.X25519(priv, curve25519.Basepoint)
	if err != nil {
		fail(err)
	}
	fmt.Println("public  (client/lib/domain/safety/moderation_key.dart):", base64.StdEncoding.EncodeToString(pub))
	fmt.Println("private (MIUCHIO_MOD_KEY, keep off the server):", base64.StdEncoding.EncodeToString(priv))
}

func list(ctx context.Context, reports *repository.ReportRepository, all bool) {
	rows, err := reports.List(ctx, all)
	if err != nil {
		fail(err)
	}
	tw := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	fmt.Fprintln(tw, "REPORT\tKIND\tRECEIVED\tSTATUS")
	for _, r := range rows {
		status := "open"
		if r.Resolution != nil {
			status = *r.Resolution
		}
		fmt.Fprintf(tw, "%s\t%s\t%s\t%s\n", r.ID, r.Kind, r.CreatedAt.Local().Format(time.DateTime), status)
	}
	_ = tw.Flush()
}

func show(ctx context.Context, reports *repository.ReportRepository, id uuid.UUID) {
	r, err := reports.Get(ctx, id)
	if err != nil {
		fail(err)
	}
	p, err := open(r.Sealed)
	if err != nil {
		fail(err)
	}
	// Report text comes from a phone, so %q keeps terminal escapes inert
	fmt.Println("report:  ", r.ID)
	fmt.Println("kind:    ", r.Kind)
	fmt.Println("received:", r.CreatedAt.Local().Format(time.DateTime))
	fmt.Printf("reason:   %q\n", p.Reason)
	if p.Note != "" {
		fmt.Printf("note:     %q\n", p.Note)
	}
	if r.Resolution != nil {
		fmt.Println("decided: ", *r.Resolution, r.ResolvedAt.Local().Format(time.DateTime))
	}
	if p.AlbumID != r.AlbumID.String() || (r.MediaID != nil && p.MediaID != r.MediaID.String()) {
		fmt.Println("WARNING: the sealed album or photo does not match the stored row")
	}
	if r.Kind != "photo" {
		return
	}
	if err := verify(ctx, reports, r, p); err != nil {
		fmt.Println("photo:    NOT VERIFIED,", err)
	} else {
		fmt.Println("photo:    verified, the same thumbnail the uploader stored")
	}
	if len(p.Thumb) > 0 {
		name := fmt.Sprintf("report-%s.jpg", r.ID)
		if err := os.WriteFile(name, p.Thumb, 0o600); err != nil {
			fail(err)
		}
		fmt.Println("saved:   ", name, "(delete it once decided)")
	}
}

func act(ctx context.Context, reports *repository.ReportRepository, cmd string, id uuid.UUID, unverified bool) {
	r, err := reports.Get(ctx, id)
	if err != nil {
		fail(err)
	}
	// An unchecked attachment is only the reporter's word
	if r.Kind == "photo" && !unverified {
		p, err := open(r.Sealed)
		if err != nil {
			fail(err)
		}
		if err := verify(ctx, reports, r, p); err != nil {
			fail(fmt.Errorf("photo not verified (%w), decide inconclusive or pass -unverified", err))
		}
	}
	switch cmd {
	case "remove":
		err = reports.RemoveReportedMedia(ctx, r)
	case "suspend":
		err = reports.Suspend(ctx, id, subject(r))
	}
	done(cmd, id, err)
}

func suspended(ctx context.Context, reports *repository.ReportRepository) {
	rows, err := reports.ListSuspended(ctx)
	if err != nil {
		fail(err)
	}
	tw := tabwriter.NewWriter(os.Stdout, 0, 2, 2, ' ', 0)
	fmt.Fprintln(tw, "MIUCHIO ID\tSUSPENDED")
	for _, s := range rows {
		fmt.Fprintf(tw, "%s\t%s\n", s.MiuchioID, s.SuspendedAt.Local().Format(time.DateTime))
	}
	_ = tw.Flush()
}

// verify decrypts the stored thumbnail with the key from the report and
// compares it with the attachment
func verify(ctx context.Context, reports *repository.ReportRepository, r repository.Report, p payload) error {
	if r.MediaID == nil || len(p.Thumb) == 0 || len(p.ThumbKey) != 32 {
		return errors.New("the report carries no thumbnail or key")
	}
	key, sha, err := reports.StoredThumb(ctx, r)
	if err != nil {
		return fmt.Errorf("the reported upload is no longer stored: %w", err)
	}
	wire, err := download(ctx, key)
	if err != nil {
		return err
	}
	if sum := sha256.Sum256(wire); !bytes.Equal(sum[:], sha) {
		return errors.New("the stored object does not match its checksum")
	}
	if len(wire) < wireHeader {
		return errors.New("the stored thumbnail is malformed")
	}
	block, err := aes.NewCipher(p.ThumbKey)
	if err != nil {
		return err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return err
	}
	nonce := wire[1 : 1+wireNonceLen]
	sealed := append(append([]byte{}, wire[wireHeader:]...), wire[1+wireNonceLen:wireHeader]...)
	aad := append(append([]byte{}, r.MediaID[:]...), "thumb"...)
	pt, err := gcm.Open(nil, nonce, sealed, aad)
	if err != nil {
		return errors.New("the key in the report does not open the stored thumbnail")
	}
	if !bytes.Equal(pt, p.Thumb) {
		return errors.New("the attachment differs from the stored thumbnail")
	}
	return nil
}

func download(ctx context.Context, key string) ([]byte, error) {
	for _, k := range []string{"S3_ENDPOINT", "S3_ACCESS_KEY", "S3_SECRET_KEY", "S3_BUCKET"} {
		if os.Getenv(k) == "" {
			return nil, fmt.Errorf("%s is not set, so the photo cannot be checked", k)
		}
	}
	s3, err := storage.NewS3Client(os.Getenv("S3_ENDPOINT"), os.Getenv("S3_PUBLIC_ENDPOINT"),
		os.Getenv("S3_ACCESS_KEY"), os.Getenv("S3_SECRET_KEY"), os.Getenv("S3_BUCKET"),
		envOr("S3_REGION", "auto"), envOr("USE_PATH_STYLE", "true") == "true")
	if err != nil {
		return nil, err
	}
	url, err := s3.GetPresignedDownloadURL(ctx, key, time.Minute)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("storage returned %d", resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, maxThumb))
}

func subject(r repository.Report) uuid.UUID {
	key, err := base64.StdEncoding.DecodeString(mustEnv("MIUCHIO_USER_LINK_KEY"))
	if err != nil {
		fail(err)
	}
	linker, err := userlink.New(key)
	if err != nil {
		fail(err)
	}
	u, err := linker.Open(r.SubjectEnc, r.SubjectToken)
	if err != nil {
		fail(err)
	}
	return u
}

func open(sealed []byte) (payload, error) {
	priv, err := base64.StdEncoding.DecodeString(mustEnv("MIUCHIO_MOD_KEY"))
	if err != nil || len(priv) != curve25519.ScalarSize {
		return payload{}, errors.New("MIUCHIO_MOD_KEY must be the base64 private key from keygen")
	}
	pubBytes, err := curve25519.X25519(priv, curve25519.Basepoint)
	if err != nil {
		return payload{}, err
	}
	var pub, sk [32]byte
	copy(pub[:], pubBytes)
	copy(sk[:], priv)
	pt, ok := box.OpenAnonymous(nil, sealed, &pub, &sk)
	if !ok {
		return payload{}, errors.New("report does not open with this key")
	}
	var p payload
	if err := json.Unmarshal(pt, &p); err != nil {
		return payload{}, err
	}
	return p, nil
}

func reportArg(args []string, fs *flag.FlagSet) uuid.UUID {
	if len(args) == 0 {
		usage()
	}
	id, err := uuid.Parse(args[0])
	if err != nil {
		fail(err)
	}
	if fs != nil {
		_ = fs.Parse(args[1:])
	}
	return id
}

func done(cmd string, target any, err error) {
	if err != nil {
		fail(err)
	}
	fmt.Println(cmd, "done for", target)
}

func mustEnv(key string) string {
	v := os.Getenv(key)
	if v == "" {
		fail(fmt.Errorf("%s is not set", key))
	}
	return v
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: mod keygen | list [-all] | show <report> | dismiss|inconclusive <report> | remove|suspend <report> [-unverified] | suspended | unsuspend <miuchio-id>")
	os.Exit(2)
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "mod:", err)
	os.Exit(1)
}
