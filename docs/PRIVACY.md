# Privacy boundary

Worklogger collects only state evidence needed to distinguish work from private
or uncertain time.

**Never collected:** keystrokes, command text, document/email/chat contents,
screenshots, window titles, clipboard contents, or full browsing history.

**Local only:** foreground application identifiers, unrecognized/private app
details, raw browser host evidence from any future opt-in adapter, lock/sleep
events, and aggregate idle duration. Raw records classified as private are
deleted after `privateRetentionHours` (24 hours by default).

**Eligible for loopback sync:** event ID/time/type, a coarse source, derived
state, and a minimal work topic only when classification says work or meeting.
All other activity becomes `private_activity`; private application, host, and
repository values never cross `PrivacyBoundary`.

The SQLite buffer preserves raw observations separately from derived
classifications. Rules can therefore be rerun without rewriting evidence.
Manual corrections are immutable rows with creation/effective timestamps.

The server binds to `127.0.0.1`, uses idempotency IDs as primary keys, and keeps
observations and corrections separately. `.env` is ignored; credentials and
other secrets must be supplied through environment variables.

Any new collector must emit the shared `Observation` model and must pass
outbound data through `PrivacyBoundary`. A collector that needs content,
commands, titles, screenshots, or global browsing history is out of scope and
must not be added.
