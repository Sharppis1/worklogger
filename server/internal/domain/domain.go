package domain

import (
	"errors"
	"strings"
	"time"
)

type Activity string

const (
	ActivityWork    Activity = "work"
	ActivityMeeting Activity = "meeting"
	ActivityPrivate Activity = "private_activity"
)

type Observation struct {
	ID         string    `json:"id"`
	OccurredAt time.Time `json:"occurred_at"`
	Kind       string    `json:"kind"`
	Activity   Activity  `json:"activity"`
	Source     string    `json:"source"`
	WorkTopic  string    `json:"work_topic,omitempty"`
	ReceivedAt time.Time `json:"received_at"`
}

type Correction struct {
	ID             string     `json:"id"`
	CreatedAt      time.Time  `json:"created_at"`
	EffectiveFrom  time.Time  `json:"effective_from"`
	EffectiveUntil *time.Time `json:"effective_until,omitempty"`
	Kind           string     `json:"kind"`
	Topic          string     `json:"topic,omitempty"`
	ReceivedAt     time.Time  `json:"received_at"`
}

type StateEvent struct {
	ID         string
	OccurredAt time.Time
	Activity   Activity
	WorkTopic  string
}

type SummaryInput struct {
	Events      []StateEvent
	Corrections []Correction
}

type DailySummary struct {
	Date                   string           `json:"date"`
	Timezone               string           `json:"timezone"`
	WorkSeconds            int64            `json:"work_seconds"`
	PrivateActivitySeconds int64            `json:"private_activity_seconds"`
	IdleSeconds            int64            `json:"idle_seconds"`
	WorkByTopicSeconds     map[string]int64 `json:"work_by_topic_seconds,omitempty"`
}

var observationKinds = map[string]struct{}{
	"active_application": {}, "idle": {}, "screen_locked": {}, "screen_unlocked": {},
	"sleep": {}, "wake": {}, "browser_host": {}, "repository_context": {},
	"windows_guest": {}, "calendar_intent": {}, "manual": {},
}

var sources = map[string]struct{}{
	"macos": {}, "manual": {}, "demo": {}, "shell": {}, "windows_guest": {},
	"calendar": {}, "integration": {},
}

var correctionKinds = map[string]struct{}{
	"mark_work": {}, "topic": {}, "break": {}, "paper_planning": {},
	"pause": {}, "resume": {}, "previous_interval_work": {},
}

func ValidateObservation(value Observation) error {
	if value.OccurredAt.IsZero() {
		return errors.New("occurred_at is required")
	}
	if _, ok := observationKinds[value.Kind]; !ok {
		return errors.New("invalid observation kind")
	}
	if _, ok := sources[value.Source]; !ok {
		return errors.New("invalid source")
	}
	switch value.Activity {
	case ActivityWork, ActivityMeeting:
		if len(value.WorkTopic) > 64 {
			return errors.New("work_topic cannot exceed 64 characters")
		}
	case ActivityPrivate:
		if strings.TrimSpace(value.WorkTopic) != "" {
			return errors.New("work_topic is not allowed for private_activity")
		}
	default:
		return errors.New("activity must be work, meeting, or private_activity")
	}
	return nil
}

func ValidateCorrection(value Correction) error {
	if value.CreatedAt.IsZero() || value.EffectiveFrom.IsZero() {
		return errors.New("created_at and effective_from are required")
	}
	if value.EffectiveUntil != nil && !value.EffectiveUntil.After(value.EffectiveFrom) {
		return errors.New("effective_until must be after effective_from")
	}
	if _, ok := correctionKinds[value.Kind]; !ok {
		return errors.New("invalid correction kind")
	}
	if len(value.Topic) > 64 {
		return errors.New("topic cannot exceed 64 characters")
	}
	switch value.Kind {
	case "mark_work", "topic", "paper_planning", "previous_interval_work":
	default:
		if strings.TrimSpace(value.Topic) != "" {
			return errors.New("topic is only allowed for work corrections")
		}
	}
	return nil
}

func CorrectionActivity(kind string) (Activity, bool) {
	switch kind {
	case "mark_work", "topic", "paper_planning", "previous_interval_work":
		return ActivityWork, true
	case "break", "pause":
		return ActivityPrivate, true
	default:
		return "", false
	}
}
