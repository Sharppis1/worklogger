package api

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/mikko/worklogger/server/internal/domain"
	"github.com/mikko/worklogger/server/internal/store"
)

type API struct {
	store store.Store
	now   func() time.Time
}

func New(s store.Store) http.Handler {
	return newAPI(s, time.Now)
}

func newAPI(s store.Store, now func() time.Time) http.Handler {
	a := &API{store: s, now: now}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", a.health)
	mux.HandleFunc("POST /v1/observations", a.createObservation)
	mux.HandleFunc("POST /v1/corrections", a.createCorrection)
	mux.HandleFunc("GET /v1/summaries/daily", a.dailySummary)
	mux.Handle("GET /", dashboardHandler())
	return securityHeaders(mux)
}

type observationRequest struct {
	ID         string          `json:"id"`
	OccurredAt time.Time       `json:"occurred_at"`
	Kind       string          `json:"kind"`
	Activity   domain.Activity `json:"activity"`
	Source     string          `json:"source"`
	WorkTopic  string          `json:"work_topic,omitempty"`
}

type correctionRequest struct {
	ID             string     `json:"id"`
	CreatedAt      time.Time  `json:"created_at"`
	EffectiveFrom  time.Time  `json:"effective_from"`
	EffectiveUntil *time.Time `json:"effective_until"`
	Kind           string     `json:"kind"`
	Topic          string     `json:"topic,omitempty"`
}

func (a *API) health(w http.ResponseWriter, r *http.Request) {
	if err := a.store.Ping(r.Context()); err != nil {
		writeError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (a *API) createObservation(w http.ResponseWriter, r *http.Request) {
	var request observationRequest
	if err := decodeJSON(w, r, &request); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if !validUUID(request.ID) {
		writeError(w, http.StatusBadRequest, "id must be a UUID")
		return
	}
	item := domain.Observation{
		ID: request.ID, OccurredAt: request.OccurredAt, Kind: request.Kind,
		Activity: request.Activity, Source: request.Source,
		WorkTopic: strings.TrimSpace(request.WorkTopic), ReceivedAt: a.now().UTC(),
	}
	if err := domain.ValidateObservation(item); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	saved, created, err := a.store.CreateObservation(r.Context(), item)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeCreatedOrExisting(w, created, saved)
}

func (a *API) createCorrection(w http.ResponseWriter, r *http.Request) {
	var request correctionRequest
	if err := decodeJSON(w, r, &request); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if !validUUID(request.ID) {
		writeError(w, http.StatusBadRequest, "id must be a UUID")
		return
	}
	item := domain.Correction{
		ID: request.ID, CreatedAt: request.CreatedAt, EffectiveFrom: request.EffectiveFrom,
		EffectiveUntil: request.EffectiveUntil, Kind: request.Kind,
		Topic: strings.TrimSpace(request.Topic), ReceivedAt: a.now().UTC(),
	}
	if err := domain.ValidateCorrection(item); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	saved, created, err := a.store.CreateCorrection(r.Context(), item)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeCreatedOrExisting(w, created, saved)
}

func (a *API) dailySummary(w http.ResponseWriter, r *http.Request) {
	dateText, timezone := r.URL.Query().Get("date"), r.URL.Query().Get("timezone")
	if dateText == "" || timezone == "" {
		writeError(w, http.StatusBadRequest, "date and timezone are required")
		return
	}
	location, err := time.LoadLocation(timezone)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid timezone")
		return
	}
	date, err := time.ParseInLocation("2006-01-02", dateText, location)
	if err != nil {
		writeError(w, http.StatusBadRequest, "date must use YYYY-MM-DD")
		return
	}
	start := time.Date(date.Year(), date.Month(), date.Day(), 0, 0, 0, 0, location)
	end := start.AddDate(0, 0, 1)
	now := a.now()
	if !now.After(start) {
		writeJSON(w, http.StatusOK, emptySummary(dateText, timezone))
		return
	}
	if now.Before(end) {
		end = now
	}
	input, err := a.store.SummaryInput(r.Context(), start.UTC(), end.UTC())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	writeJSON(w, http.StatusOK, summarize(dateText, timezone, start, end, input))
}

func summarize(date, timezone string, start, end time.Time, input domain.SummaryInput) domain.DailySummary {
	result := emptySummary(date, timezone)
	boundaries := []time.Time{start, end}
	for _, event := range input.Events {
		if event.OccurredAt.After(start) && event.OccurredAt.Before(end) {
			boundaries = append(boundaries, event.OccurredAt)
		}
	}
	for _, correction := range input.Corrections {
		if correction.EffectiveFrom.After(start) && correction.EffectiveFrom.Before(end) {
			boundaries = append(boundaries, correction.EffectiveFrom)
		}
		if correction.EffectiveUntil != nil && correction.EffectiveUntil.After(start) && correction.EffectiveUntil.Before(end) {
			boundaries = append(boundaries, *correction.EffectiveUntil)
		}
	}
	sort.Slice(boundaries, func(i, j int) bool { return boundaries[i].Before(boundaries[j]) })
	for i := 0; i+1 < len(boundaries); i++ {
		from, to := boundaries[i], boundaries[i+1]
		if !to.After(from) {
			continue
		}
		activity, topic, ok := stateAt(from, input)
		if !ok {
			continue
		}
		seconds := int64(to.Sub(from) / time.Second)
		if activity == domain.ActivityWork || activity == domain.ActivityMeeting {
			result.WorkSeconds += seconds
			if topic != "" {
				result.WorkByTopicSeconds[topic] += seconds
			}
		} else {
			result.PrivateActivitySeconds += seconds
		}
	}
	if len(result.WorkByTopicSeconds) == 0 {
		result.WorkByTopicSeconds = nil
	}
	return result
}

func stateAt(at time.Time, input domain.SummaryInput) (domain.Activity, string, bool) {
	var event *domain.StateEvent
	for i := range input.Events {
		candidate := &input.Events[i]
		if !candidate.OccurredAt.After(at) &&
			(event == nil || candidate.OccurredAt.After(event.OccurredAt) ||
				(candidate.OccurredAt.Equal(event.OccurredAt) && candidate.ID > event.ID)) {
			event = candidate
		}
	}
	var correction *domain.Correction
	for i := range input.Corrections {
		candidate := &input.Corrections[i]
		active := !candidate.EffectiveFrom.After(at) &&
			(candidate.EffectiveUntil == nil || candidate.EffectiveUntil.After(at))
		if active && (correction == nil || candidate.CreatedAt.After(correction.CreatedAt) ||
			(candidate.CreatedAt.Equal(correction.CreatedAt) && candidate.ID > correction.ID)) {
			correction = candidate
		}
	}
	if correction != nil {
		if activity, applies := domain.CorrectionActivity(correction.Kind); applies {
			return activity, correction.Topic, true
		}
	}
	if event == nil {
		return "", "", false
	}
	return event.Activity, event.WorkTopic, true
}

func emptySummary(date, timezone string) domain.DailySummary {
	return domain.DailySummary{
		Date: date, Timezone: timezone, WorkByTopicSeconds: map[string]int64{},
	}
}

func decodeJSON(w http.ResponseWriter, r *http.Request, target any) error {
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return errors.New("invalid JSON: " + err.Error())
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return errors.New("request body must contain one JSON object")
	}
	return nil
}

func validUUID(id string) bool {
	if len(id) != 36 {
		return false
	}
	for i, c := range id {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' {
				return false
			}
			continue
		}
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
			return false
		}
	}
	return true
}

func writeStoreError(w http.ResponseWriter, err error) {
	if errors.Is(err, store.ErrConflict) {
		writeError(w, http.StatusConflict, err.Error())
		return
	}
	writeError(w, http.StatusInternalServerError, "internal error")
}

func writeCreatedOrExisting(w http.ResponseWriter, created bool, body any) {
	status := http.StatusOK
	if created {
		status = http.StatusCreated
	}
	writeJSON(w, status, body)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; connect-src 'self'; img-src 'self'; script-src 'self'; style-src 'self'; base-uri 'none'; frame-ancestors 'none'")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		next.ServeHTTP(w, r)
	})
}
