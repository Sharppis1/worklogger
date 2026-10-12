package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/mikko/worklogger/server/internal/domain"
	"github.com/mikko/worklogger/server/internal/store"
)

func TestDashboardAndAssetsAreServed(t *testing.T) {
	handler := New(newFakeStore())

	page := request(t, handler, http.MethodGet, "/", "")
	if page.Code != http.StatusOK {
		t.Fatalf("dashboard status = %d, body = %s", page.Code, page.Body)
	}
	if !bytes.Contains(page.Body.Bytes(), []byte("<title>Worklogger reports</title>")) {
		t.Fatalf("dashboard title missing: %s", page.Body)
	}
	if policy := page.Header().Get("Content-Security-Policy"); policy == "" {
		t.Fatal("dashboard response is missing Content-Security-Policy")
	}

	script := request(t, handler, http.MethodGet, "/app.js", "")
	if script.Code != http.StatusOK {
		t.Fatalf("script status = %d, body = %s", script.Code, script.Body)
	}
	if contentType := script.Header().Get("Content-Type"); contentType != "text/javascript; charset=utf-8" {
		t.Fatalf("script Content-Type = %q", contentType)
	}
}

const (
	observationID = "0199d1df-4b78-7bbd-9d3d-9e5031e78223"
	correctionID  = "0199d1df-4b78-7bbd-9d3d-9e5031e78224"
)

type fakeStore struct {
	mu           sync.Mutex
	observations map[string]domain.Observation
	corrections  map[string]domain.Correction
}

func newFakeStore() *fakeStore {
	return &fakeStore{
		observations: map[string]domain.Observation{},
		corrections:  map[string]domain.Correction{},
	}
}

func (f *fakeStore) Ping(context.Context) error { return nil }

func (f *fakeStore) CreateObservation(_ context.Context, value domain.Observation) (domain.Observation, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if saved, ok := f.observations[value.ID]; ok {
		if saved.OccurredAt.Equal(value.OccurredAt) && saved.Kind == value.Kind &&
			saved.Activity == value.Activity && saved.Source == value.Source &&
			saved.WorkTopic == value.WorkTopic {
			return saved, false, nil
		}
		return domain.Observation{}, false, store.ErrConflict
	}
	f.observations[value.ID] = value
	return value, true, nil
}

func (f *fakeStore) CreateCorrection(_ context.Context, value domain.Correction) (domain.Correction, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if saved, ok := f.corrections[value.ID]; ok {
		if saved.CreatedAt.Equal(value.CreatedAt) && saved.EffectiveFrom.Equal(value.EffectiveFrom) &&
			equalTestTime(saved.EffectiveUntil, value.EffectiveUntil) &&
			saved.Kind == value.Kind && saved.Topic == value.Topic {
			return saved, false, nil
		}
		return domain.Correction{}, false, store.ErrConflict
	}
	f.corrections[value.ID] = value
	return value, true, nil
}

func (f *fakeStore) SummaryInput(_ context.Context, start, end time.Time) (domain.SummaryInput, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var result domain.SummaryInput
	var prior *domain.StateEvent
	for _, observation := range f.observations {
		event := domain.StateEvent{
			ID: observation.ID, OccurredAt: observation.OccurredAt,
			Activity: observation.Activity, WorkTopic: observation.WorkTopic,
		}
		if observation.OccurredAt.Before(start) {
			if prior == nil || observation.OccurredAt.After(prior.OccurredAt) {
				copy := event
				prior = &copy
			}
		} else if observation.OccurredAt.Before(end) {
			result.Events = append(result.Events, event)
		}
	}
	if prior != nil {
		result.Events = append(result.Events, *prior)
	}
	for _, correction := range f.corrections {
		if correction.EffectiveFrom.Before(end) &&
			(correction.EffectiveUntil == nil || correction.EffectiveUntil.After(start)) {
			result.Corrections = append(result.Corrections, correction)
		}
	}
	return result, nil
}

func TestFixedObservationEnvelopeIsIdempotent(t *testing.T) {
	handler := New(newFakeStore())
	body := `{"id":"` + observationID + `","occurred_at":"2026-10-11T08:00:00Z","kind":"active_application","activity":"work","source":"macos","work_topic":"coding"}`
	if response := request(t, handler, http.MethodPost, "/v1/observations", body); response.Code != http.StatusCreated {
		t.Fatalf("first status = %d, body = %s", response.Code, response.Body)
	}
	if response := request(t, handler, http.MethodPost, "/v1/observations", body); response.Code != http.StatusOK {
		t.Fatalf("retry status = %d, body = %s", response.Code, response.Body)
	}
	conflict := `{"id":"` + observationID + `","occurred_at":"2026-10-11T08:01:00Z","kind":"active_application","activity":"work","source":"macos"}`
	if response := request(t, handler, http.MethodPost, "/v1/observations", conflict); response.Code != http.StatusConflict {
		t.Fatalf("conflict status = %d, body = %s", response.Code, response.Body)
	}
}

func TestEnvelopeRejectsPrivateMetadataAndLegacyFields(t *testing.T) {
	handler := New(newFakeStore())
	private := `{"id":"` + observationID + `","occurred_at":"2026-10-11T08:00:00Z","kind":"idle","activity":"private_activity","source":"macos","work_topic":"sensitive"}`
	if response := request(t, handler, http.MethodPost, "/v1/observations", private); response.Code != http.StatusBadRequest {
		t.Fatalf("private metadata status = %d, body = %s", response.Code, response.Body)
	}
	legacy := `{"id":"` + observationID + `","started_at":"2026-10-11T08:00:00Z","kind":"idle","activity":"private_activity","source":"macos"}`
	if response := request(t, handler, http.MethodPost, "/v1/observations", legacy); response.Code != http.StatusBadRequest {
		t.Fatalf("legacy status = %d, body = %s", response.Code, response.Body)
	}
}

func TestCorrectionEnvelopeIsImmutableAndIdempotent(t *testing.T) {
	fake := newFakeStore()
	handler := New(fake)
	body := `{"id":"` + correctionID + `","created_at":"2026-10-11T09:00:00Z","effective_from":"2026-10-11T08:00:00Z","effective_until":"2026-10-11T09:00:00Z","kind":"mark_work","topic":"coding"}`
	if response := request(t, handler, http.MethodPost, "/v1/corrections", body); response.Code != http.StatusCreated {
		t.Fatalf("first status = %d, body = %s", response.Code, response.Body)
	}
	if response := request(t, handler, http.MethodPost, "/v1/corrections", body); response.Code != http.StatusOK {
		t.Fatalf("retry status = %d, body = %s", response.Code, response.Body)
	}
	if len(fake.corrections) != 1 {
		t.Fatalf("correction count = %d", len(fake.corrections))
	}
}

func TestPointTransitionsSplitAtMidnightAndDST(t *testing.T) {
	fake := newFakeStore()
	fake.observations[observationID] = domain.Observation{
		ID: observationID, OccurredAt: mustTime(t, "2026-10-24T20:30:00Z"),
		Kind: "active_application", Activity: domain.ActivityWork,
		Source: "macos", WorkTopic: "coding",
	}
	handler := newAPI(fake, func() time.Time { return mustTime(t, "2026-10-26T12:00:00Z") })
	response := request(t, handler, http.MethodGet, "/v1/summaries/daily?date=2026-10-25&timezone=Europe%2FHelsinki", "")
	var summary domain.DailySummary
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body)
	}
	if err := json.Unmarshal(response.Body.Bytes(), &summary); err != nil {
		t.Fatal(err)
	}
	if summary.WorkSeconds != 25*60*60 || summary.WorkByTopicSeconds["coding"] != 25*60*60 {
		t.Fatalf("unexpected summary: %+v", summary)
	}
}

func TestFinalPointIsCappedAtQueryTimeAndCorrectionOverrides(t *testing.T) {
	fake := newFakeStore()
	fake.observations[observationID] = domain.Observation{
		ID: observationID, OccurredAt: mustTime(t, "2026-10-12T06:00:00Z"),
		Kind: "active_application", Activity: domain.ActivityPrivate, Source: "macos",
	}
	until := mustTime(t, "2026-10-12T08:00:00Z")
	fake.corrections[correctionID] = domain.Correction{
		ID: correctionID, CreatedAt: mustTime(t, "2026-10-12T07:30:00Z"),
		EffectiveFrom: mustTime(t, "2026-10-12T07:00:00Z"), EffectiveUntil: &until,
		Kind: "mark_work", Topic: "planning",
	}
	handler := newAPI(fake, func() time.Time { return mustTime(t, "2026-10-12T09:00:00Z") })
	response := request(t, handler, http.MethodGet, "/v1/summaries/daily?date=2026-10-12&timezone=UTC", "")
	var summary domain.DailySummary
	if err := json.Unmarshal(response.Body.Bytes(), &summary); err != nil {
		t.Fatal(err)
	}
	if summary.WorkSeconds != 3600 || summary.PrivateActivitySeconds != 2*3600 {
		t.Fatalf("unexpected now-capped summary: %+v", summary)
	}
}

func request(t *testing.T, handler http.Handler, method, target, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, target, bytes.NewBufferString(body))
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, req)
	return response
}

func mustTime(t *testing.T, value string) time.Time {
	t.Helper()
	parsed, err := time.Parse(time.RFC3339, value)
	if err != nil {
		t.Fatal(err)
	}
	return parsed
}

func equalTestTime(a, b *time.Time) bool {
	return (a == nil && b == nil) || (a != nil && b != nil && a.Equal(*b))
}
