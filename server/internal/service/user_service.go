package service

import (
	"context"

	"github.com/freytastic/miuchio/internal/model"
	"github.com/freytastic/miuchio/internal/repository"
	"github.com/google/uuid"
)

type UserStore interface {
	GetByID(ctx context.Context, id uuid.UUID) (*model.User, error)
	SetDeleteMediaOnLeave(ctx context.Context, id uuid.UUID, on bool) error
}

type StorageReader interface {
	Usage(ctx context.Context, userID uuid.UUID) (repository.StorageUsage, error)
}

type UserService struct {
	userRepo UserStore
	storage  StorageReader
}

func NewUserService(userRepo UserStore, storage StorageReader) *UserService {
	return &UserService{userRepo: userRepo, storage: storage}
}

func (s *UserService) GetUserByID(ctx context.Context, id uuid.UUID) (*model.User, error) {
	return s.userRepo.GetByID(ctx, id)
}

func (s *UserService) SetDeleteMediaOnLeave(ctx context.Context, id uuid.UUID, on bool) error {
	return s.userRepo.SetDeleteMediaOnLeave(ctx, id, on)
}

func (s *UserService) StorageUsage(ctx context.Context, id uuid.UUID) (repository.StorageUsage, error) {
	return s.storage.Usage(ctx, id)
}
