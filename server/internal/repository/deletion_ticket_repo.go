package repository

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

// DeletionTicket is what a verified web deletion code authorizes. It names the
// account by its immutable id, never by email, so a later account on the same
// address is out of its reach
type DeletionTicket struct {
	UserID         uuid.UUID   `json:"user_id"`
	SharedAlbumIDs []uuid.UUID `json:"shared_album_ids"`
}

// Tickets are stored under their hash, so Redis never holds a usable one
type DeletionTicketRepository struct {
	Redis *redis.Client
}

func NewDeletionTicketRepository(rdb *redis.Client) *DeletionTicketRepository {
	return &DeletionTicketRepository{Redis: rdb}
}

func ticketKey(hash []byte) string {
	return "deletion-ticket:" + hex.EncodeToString(hash)
}

func (r *DeletionTicketRepository) PutTicket(ctx context.Context, hash []byte, t DeletionTicket, ttl time.Duration) error {
	body, err := json.Marshal(t)
	if err != nil {
		return err
	}
	return r.Redis.Set(ctx, ticketKey(hash), body, ttl).Err()
}

// TakeTicket reads and deletes in one step, so parallel confirmations of one
// ticket cannot both get it
func (r *DeletionTicketRepository) TakeTicket(ctx context.Context, hash []byte) (DeletionTicket, bool, error) {
	body, err := r.Redis.GetDel(ctx, ticketKey(hash)).Bytes()
	if errors.Is(err, redis.Nil) {
		return DeletionTicket{}, false, nil
	}
	if err != nil {
		return DeletionTicket{}, false, err
	}
	var t DeletionTicket
	if err := json.Unmarshal(body, &t); err != nil {
		return DeletionTicket{}, false, err
	}
	return t, true, nil
}
