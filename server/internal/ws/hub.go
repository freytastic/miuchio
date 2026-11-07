package ws

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/google/uuid"
)

// Hub manages all active WebSocket connections, keyed by user ID
// One user may hold several connections
type Hub struct {
	mu    sync.RWMutex
	conns map[uuid.UUID][]*Conn
}

func NewHub() *Hub {
	return &Hub{conns: make(map[uuid.UUID][]*Conn)}
}

func (h *Hub) Register(userID uuid.UUID, c *Conn) {
	h.mu.Lock()
	h.conns[userID] = append(h.conns[userID], c)
	h.mu.Unlock()
}

func (h *Hub) Unregister(userID uuid.UUID, c *Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	list := h.conns[userID]
	out := list[:0]
	for _, existing := range list {
		if existing != c {
			out = append(out, existing)
		}
	}
	if len(out) == 0 {
		delete(h.conns, userID)
	} else {
		h.conns[userID] = out
	}
}

// Disconnect closes every connection the user holds
func (h *Hub) Disconnect(userID uuid.UUID) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, c := range h.conns[userID] {
		c.close()
	}
}

func (h *Hub) users() []uuid.UUID {
	h.mu.RLock()
	defer h.mu.RUnlock()
	out := make([]uuid.UUID, 0, len(h.conns))
	for id := range h.conns {
		out = append(out, id)
	}
	return out
}

// RunEviction closes connections of accounts that lost access elsewhere, such
// as a suspension made by the moderation tool in another process
func (h *Hub) RunEviction(ctx context.Context, every time.Duration, inactive func(context.Context, []uuid.UUID) ([]uuid.UUID, error)) {
	ticker := time.NewTicker(every)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			ids := h.users()
			if len(ids) == 0 {
				continue
			}
			gone, err := inactive(ctx, ids)
			if err != nil {
				slog.ErrorContext(ctx, "ws eviction check failed", "err", err)
				continue
			}
			for _, id := range gone {
				h.Disconnect(id)
			}
		}
	}
}

// Broadcast delivers event to every active connection for the given users
// Slow clients with a full outbox miss the event
func (h *Hub) Broadcast(userIDs []uuid.UUID, event Event) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, uid := range userIDs {
		for _, c := range h.conns[uid] {
			c.send(event)
		}
	}
}

// EmitToUsers is live only, offline recipients catch up by pulling on their next
// reconnect
func (h *Hub) EmitToUsers(_ context.Context, userIDs []uuid.UUID, typ string, payload any) error {
	ev, err := NewEvent(typ, payload)
	if err != nil {
		return err
	}
	h.Broadcast(userIDs, ev)
	return nil
}
