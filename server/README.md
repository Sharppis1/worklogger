# Worklogger server

Small Go HTTP service backed by PostgreSQL. Raw point observations and immutable
corrections are retained separately from the effective state used for summaries.
Only a short optional `work_topic` is accepted; `private_activity` is a generic
privacy boundary and cannot contain metadata.

Start locally from the repository root:

```sh
docker compose up --build
```

The reporting dashboard and API listen on `http://127.0.0.1:8787`. The
dashboard shows daily totals, work topics, and a seven-day comparison. Configure `POSTGRES_PASSWORD` in the
environment for a non-default local password. Production deployments must set
their own `DATABASE_URL`.

## API

- `GET /healthz`
- `POST /v1/observations`
- `POST /v1/corrections`
- `GET /v1/summaries/daily?date=YYYY-MM-DD&timezone=Europe/Helsinki`

Observation example:

```json
{
  "id": "0199d1df-4b78-7bbd-9d3d-9e5031e78223",
  "occurred_at": "2026-10-12T08:00:00Z",
  "kind": "active_application",
  "activity": "work",
  "source": "macos",
  "work_topic": "coding"
}
```

Corrections contain `id`, client `created_at`, `effective_from`, optional
`effective_until`, `kind`, and optional `topic`. IDs are idempotency keys: an
identical retry returns 200, while reuse with different content returns 409.
New resources return 201.

Daily summaries treat observations as state transitions lasting until the next
observation. The final state is capped at query time, and intervals are clipped
to the requested local calendar day (including daylight-saving transitions).

Run tests with `go test ./...`.
