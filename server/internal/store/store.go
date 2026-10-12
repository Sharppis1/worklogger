package store

import (
	"context"
	"errors"
	"time"

	"github.com/mikko/worklogger/server/internal/domain"
)

var ErrConflict = errors.New("idempotency key already used with different content")

type Store interface {
	Ping(context.Context) error
	CreateObservation(context.Context, domain.Observation) (domain.Observation, bool, error)
	CreateCorrection(context.Context, domain.Correction) (domain.Correction, bool, error)
	SummaryInput(context.Context, time.Time, time.Time) (domain.SummaryInput, error)
}
