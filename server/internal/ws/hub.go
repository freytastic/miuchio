package ws

import (
	"context"
	"sync"

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
