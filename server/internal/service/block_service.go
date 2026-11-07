package service

import (
	"context"
	"errors"

	"github.com/freytastic/miuchio/internal/apierr"
	"github.com/freytastic/miuchio/internal/repository"
	"github.com/freytastic/miuchio/internal/userlink"
	"github.com/google/uuid"
)

type BlockStore interface {
	Create(ctx context.Context, blocker, pair []byte) (repository.Block, error)
	List(ctx context.Context, blocker []byte) ([]repository.Block, error)
	Delete(ctx context.Context, blocker []byte, id uuid.UUID) error
}

type AlbumMemberResolver interface {
	UserIDByAlbumMemberToken(ctx context.Context, albumID uuid.UUID, token []byte) (uuid.UUID, error)
}

// Blocks stop either person adding the other to an album. Existing shared
// albums are left alone, the app offers to leave or remove instead
type BlockService struct {
	repo    BlockStore
	members AlbumMemberResolver
	linker  *userlink.Hasher
}

func NewBlockService(repo BlockStore, members AlbumMemberResolver, linker *userlink.Hasher) *BlockService {
	return &BlockService{repo: repo, members: members, linker: linker}
}

func (s *BlockService) Block(ctx context.Context, albumID, callerID uuid.UUID, targetToken []byte) (repository.Block, error) {
	target, err := s.members.UserIDByAlbumMemberToken(ctx, albumID, targetToken)
	if errors.Is(err, repository.ErrMemberNotFound) {
		return repository.Block{}, apierr.NotFound("member not found")
	}
	if err != nil {
		return repository.Block{}, apierr.Internal("failed to resolve member").WithCause(err)
	}
	if target == callerID {
		return repository.Block{}, apierr.Validation("you can't block yourself")
	}
	b, err := s.repo.Create(ctx, s.linker.BlockerHash(callerID), s.linker.BlockPair(callerID, target))
	if err != nil {
		return repository.Block{}, apierr.Internal("failed to block").WithCause(err)
	}
	return b, nil
}

func (s *BlockService) List(ctx context.Context, callerID uuid.UUID) ([]repository.Block, error) {
	out, err := s.repo.List(ctx, s.linker.BlockerHash(callerID))
	if err != nil {
		return nil, apierr.Internal("failed to list blocks").WithCause(err)
	}
	return out, nil
}

func (s *BlockService) Unblock(ctx context.Context, callerID, id uuid.UUID) error {
	err := s.repo.Delete(ctx, s.linker.BlockerHash(callerID), id)
	if errors.Is(err, repository.ErrBlockNotFound) {
		return apierr.NotFound("block not found")
	}
	if err != nil {
		return apierr.Internal("failed to unblock").WithCause(err)
	}
	return nil
}
