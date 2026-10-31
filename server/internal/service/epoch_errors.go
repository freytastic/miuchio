package service

import (
	"errors"

	"github.com/freytastic/miuchio/internal/apierr"
	"github.com/freytastic/miuchio/internal/repository"
)

// Nil unless the epoch gate refused the upload. Both refusals tell the client
// to reseal under the newest key once rotation has committed
func epochErr(err error) error {
	switch {
	case errors.Is(err, repository.ErrNoEpoch):
		return apierr.Validation("album has no epoch yet ; cannot upload")
	case errors.Is(err, repository.ErrEpochMismatch):
		return apierr.EpochReplay("key is not sealed under the current epoch ; reseal and retry")
	case errors.Is(err, repository.ErrPendingRotation):
		return apierr.EpochPendingRotation("album has a pending epoch rotation ; uploads are frozen until it completes")
	}
	return nil
}
