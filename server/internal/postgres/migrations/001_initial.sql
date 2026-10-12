CREATE TABLE IF NOT EXISTS observations (
    id uuid PRIMARY KEY,
    occurred_at timestamptz NOT NULL,
    kind text NOT NULL CHECK (kind IN (
        'active_application', 'idle', 'screen_locked', 'screen_unlocked',
        'sleep', 'wake', 'browser_host', 'repository_context',
        'windows_guest', 'calendar_intent', 'manual'
    )),
    activity text NOT NULL CHECK (activity IN ('work', 'meeting', 'private_activity')),
    source text NOT NULL CHECK (source IN (
        'macos', 'manual', 'demo', 'shell', 'windows_guest', 'calendar', 'integration'
    )),
    work_topic text CHECK (length(work_topic) <= 64),
    received_at timestamptz NOT NULL,
    CHECK (activity <> 'private_activity' OR work_topic IS NULL)
);

CREATE INDEX IF NOT EXISTS observations_occurred_at
    ON observations (occurred_at, id);

CREATE TABLE IF NOT EXISTS corrections (
    id uuid PRIMARY KEY,
    created_at timestamptz NOT NULL,
    effective_from timestamptz NOT NULL,
    effective_until timestamptz,
    kind text NOT NULL CHECK (kind IN (
        'mark_work', 'topic', 'break', 'paper_planning',
        'pause', 'resume', 'previous_interval_work'
    )),
    topic text CHECK (length(topic) <= 64),
    received_at timestamptz NOT NULL,
    CHECK (effective_until IS NULL OR effective_until > effective_from),
    CHECK (kind IN ('mark_work', 'topic', 'paper_planning', 'previous_interval_work') OR topic IS NULL)
);

CREATE INDEX IF NOT EXISTS corrections_effective_range
    ON corrections (effective_from, effective_until);

-- This projection is deliberately separate from immutable raw observations.
CREATE TABLE IF NOT EXISTS effective_state_events (
    observation_id uuid PRIMARY KEY REFERENCES observations(id),
    occurred_at timestamptz NOT NULL,
    activity text NOT NULL CHECK (activity IN ('work', 'meeting', 'private_activity')),
    work_topic text CHECK (length(work_topic) <= 64),
    CHECK (activity <> 'private_activity' OR work_topic IS NULL)
);

CREATE INDEX IF NOT EXISTS effective_state_events_occurred_at
    ON effective_state_events (occurred_at, observation_id);

CREATE OR REPLACE FUNCTION reject_immutable_change() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION '% rows are immutable', TG_TABLE_NAME;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS observations_immutable ON observations;
CREATE TRIGGER observations_immutable BEFORE UPDATE OR DELETE ON observations
    FOR EACH ROW EXECUTE FUNCTION reject_immutable_change();

DROP TRIGGER IF EXISTS corrections_immutable ON corrections;
CREATE TRIGGER corrections_immutable BEFORE UPDATE OR DELETE ON corrections
    FOR EACH ROW EXECUTE FUNCTION reject_immutable_change();
