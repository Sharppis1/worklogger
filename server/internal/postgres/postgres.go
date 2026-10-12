package postgres

import (
	"context"
	"embed"
	"errors"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/mikko/worklogger/server/internal/domain"
	"github.com/mikko/worklogger/server/internal/store"
)

//go:embed migrations/*.sql
var migrations embed.FS

type Store struct {
	pool *pgxpool.Pool
}

func Open(ctx context.Context, databaseURL string) (*Store, error) {
	config, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, err
	}
	config.MaxConns = 10
	config.MinConns = 1
	config.MaxConnLifetime = time.Hour
	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		return nil, err
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	return &Store{pool: pool}, nil
}

func (s *Store) Close()                         { s.pool.Close() }
func (s *Store) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }

func (s *Store) Migrate(ctx context.Context) error {
	entries, err := migrations.ReadDir("migrations")
	if err != nil {
		return err
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		sql, err := migrations.ReadFile("migrations/" + entry.Name())
		if err != nil {
			return err
		}
		if _, err := s.pool.Exec(ctx, string(sql)); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) CreateObservation(ctx context.Context, value domain.Observation) (domain.Observation, bool, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return domain.Observation{}, false, err
	}
	defer tx.Rollback(ctx)
	var saved domain.Observation
	err = tx.QueryRow(ctx, `
		INSERT INTO observations
			(id, occurred_at, kind, activity, source, work_topic, received_at)
		VALUES ($1, $2, $3, $4, $5, NULLIF($6, ''), $7)
		ON CONFLICT (id) DO NOTHING
		RETURNING id, occurred_at, kind, activity, source, COALESCE(work_topic, ''), received_at`,
		value.ID, value.OccurredAt, value.Kind, value.Activity, value.Source,
		value.WorkTopic, value.ReceivedAt,
	).Scan(&saved.ID, &saved.OccurredAt, &saved.Kind, &saved.Activity, &saved.Source,
		&saved.WorkTopic, &saved.ReceivedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		saved, err = getObservation(ctx, tx, value.ID)
		if err != nil {
			return domain.Observation{}, false, err
		}
		if !equalObservation(saved, value) {
			return domain.Observation{}, false, store.ErrConflict
		}
		return saved, false, tx.Commit(ctx)
	}
	if err != nil {
		return domain.Observation{}, false, err
	}
	_, err = tx.Exec(ctx, `
		INSERT INTO effective_state_events
			(observation_id, occurred_at, activity, work_topic)
		VALUES ($1, $2, $3, NULLIF($4, ''))`,
		saved.ID, saved.OccurredAt, saved.Activity, saved.WorkTopic)
	if err != nil {
		return domain.Observation{}, false, err
	}
	return saved, true, tx.Commit(ctx)
}

func (s *Store) CreateCorrection(ctx context.Context, value domain.Correction) (domain.Correction, bool, error) {
	var saved domain.Correction
	err := s.pool.QueryRow(ctx, `
		INSERT INTO corrections
			(id, created_at, effective_from, effective_until, kind, topic, received_at)
		VALUES ($1, $2, $3, $4, $5, NULLIF($6, ''), $7)
		ON CONFLICT (id) DO NOTHING
		RETURNING id, created_at, effective_from, effective_until, kind,
			COALESCE(topic, ''), received_at`,
		value.ID, value.CreatedAt, value.EffectiveFrom, value.EffectiveUntil,
		value.Kind, value.Topic, value.ReceivedAt,
	).Scan(&saved.ID, &saved.CreatedAt, &saved.EffectiveFrom, &saved.EffectiveUntil,
		&saved.Kind, &saved.Topic, &saved.ReceivedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		saved, err = getCorrection(ctx, s.pool, value.ID)
		if err != nil {
			return domain.Correction{}, false, err
		}
		if !equalCorrection(saved, value) {
			return domain.Correction{}, false, store.ErrConflict
		}
		return saved, false, nil
	}
	return saved, err == nil, err
}

func (s *Store) SummaryInput(ctx context.Context, start, end time.Time) (domain.SummaryInput, error) {
	var result domain.SummaryInput
	rows, err := s.pool.Query(ctx, `
		(SELECT observation_id, occurred_at, activity, COALESCE(work_topic, '')
		 FROM effective_state_events
		 WHERE occurred_at < $1
		 ORDER BY occurred_at DESC, observation_id DESC
		 LIMIT 1)
		UNION ALL
		(SELECT observation_id, occurred_at, activity, COALESCE(work_topic, '')
		 FROM effective_state_events
		 WHERE occurred_at >= $1 AND occurred_at < $2)
		ORDER BY occurred_at, observation_id`, start, end)
	if err != nil {
		return result, err
	}
	for rows.Next() {
		var event domain.StateEvent
		if err := rows.Scan(&event.ID, &event.OccurredAt, &event.Activity, &event.WorkTopic); err != nil {
			rows.Close()
			return result, err
		}
		result.Events = append(result.Events, event)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return result, err
	}
	rows.Close()

	rows, err = s.pool.Query(ctx, `
		SELECT id, created_at, effective_from, effective_until, kind,
			COALESCE(topic, ''), received_at
		FROM corrections
		WHERE effective_from < $2
		  AND (effective_until IS NULL OR effective_until > $1)
		ORDER BY created_at, id`, start, end)
	if err != nil {
		return result, err
	}
	defer rows.Close()
	for rows.Next() {
		var correction domain.Correction
		if err := rows.Scan(&correction.ID, &correction.CreatedAt, &correction.EffectiveFrom,
			&correction.EffectiveUntil, &correction.Kind, &correction.Topic, &correction.ReceivedAt); err != nil {
			return result, err
		}
		result.Corrections = append(result.Corrections, correction)
	}
	return result, rows.Err()
}

type querier interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}

func getObservation(ctx context.Context, q querier, id string) (domain.Observation, error) {
	var value domain.Observation
	err := q.QueryRow(ctx, `
		SELECT id, occurred_at, kind, activity, source, COALESCE(work_topic, ''), received_at
		FROM observations WHERE id=$1`, id).
		Scan(&value.ID, &value.OccurredAt, &value.Kind, &value.Activity, &value.Source,
			&value.WorkTopic, &value.ReceivedAt)
	return value, err
}

func getCorrection(ctx context.Context, q querier, id string) (domain.Correction, error) {
	var value domain.Correction
	err := q.QueryRow(ctx, `
		SELECT id, created_at, effective_from, effective_until, kind, COALESCE(topic, ''), received_at
		FROM corrections WHERE id=$1`, id).
		Scan(&value.ID, &value.CreatedAt, &value.EffectiveFrom, &value.EffectiveUntil,
			&value.Kind, &value.Topic, &value.ReceivedAt)
	return value, err
}

func equalObservation(a, b domain.Observation) bool {
	return a.ID == b.ID && a.OccurredAt.Equal(b.OccurredAt) && a.Kind == b.Kind &&
		a.Activity == b.Activity && a.Source == b.Source && a.WorkTopic == b.WorkTopic
}

func equalCorrection(a, b domain.Correction) bool {
	return a.ID == b.ID && a.CreatedAt.Equal(b.CreatedAt) &&
		a.EffectiveFrom.Equal(b.EffectiveFrom) && equalOptionalTime(a.EffectiveUntil, b.EffectiveUntil) &&
		a.Kind == b.Kind && a.Topic == b.Topic
}

func equalOptionalTime(a, b *time.Time) bool {
	return (a == nil && b == nil) || (a != nil && b != nil && a.Equal(*b))
}

var _ store.Store = (*Store)(nil)
