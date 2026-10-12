# Worklogger MVP

A privacy-first macOS menu-bar work logger. The native app records raw local
observations, derives a replaceable classification, accepts immutable manual
corrections, and synchronizes minimized events to a loopback-only Docker API.

## Run

Prerequisites: macOS 13+, Xcode/Swift 6, and Docker Desktop.

```bash
# Terminal 1: local API and PostgreSQL
docker compose up --build

# Terminal 2: menu-bar app with safe synthetic transitions
swift run WorkloggerApp --demo

# Or collect the real foreground app, lock/sleep state, and idle duration
swift run WorkloggerApp
```

The API listens only on `127.0.0.1:8787`. Local app data is stored at
`~/Library/Application Support/Worklogger/worklogger.sqlite3`. If Docker is
stopped, collection and the UI continue; pending events retry on each sampling
cycle after the API returns.

Open `http://localhost:8787` for the local reporting dashboard. It shows the
selected day's totals, topic breakdown, and a seven-day work-hours comparison.
The page is embedded in the Go binary and uses the same loopback-only API.

Run checks:

```bash
swift test
(cd server && go test ./...)
docker compose config --quiet
curl http://127.0.0.1:8787/healthz
```

## App behavior

The menu label and panel always identify state with both text and an SF Symbol:
**Work**, **Meeting**, **Uncertain**, **Non-work**, **Break**, or
**Tracking paused**. The panel shows the current source/topic and today's
state totals.

Manual actions can mark current or previous time as work, select a repository
topic, start a bounded break or paper-planning interval, pause for a bounded
duration, and resume. Corrections are append-only audit events. Active manual
corrections outrank automatic rules and expire at an explicit timestamp.

Real collection uses public APIs:

- `NSWorkspace` for the foreground application and sleep/wake notifications.
- Workspace session notifications for lock/unlock.
- `CGEventSource` for aggregate idle seconds.
- Accessibility is **not** needed for those basics. The menu can request it for
  future opt-in browser/repository adapters; macOS System Settings controls the
  permission.
- Chrome, Edge, and Safari active-tab context uses macOS Automation permission.
  Only the normalized hostname is retained; URL paths, queries, titles, and
  browsing history are discarded.

Simulation mode rotates through Slack, a configured repository, generic
Parallels, long idle, and locked states. Toggle it in the menu or launch with
`--demo` / `WORKLOGGER_DEMO=1`.

## Classification

Rules live in
[`default-classification.json`](Sources/WorkloggerCore/Resources/default-classification.json).
Hosts use normalized exact equality, with an explicit `includeSubdomains`
option; there is no substring matching. Jira, Confluence, Microsoft 365 apps,
Slack, Teams, configured repositories, `ansfinland.fi` subdomains, and the
exact host `extra.tie.fintraffic.fi` start as work evidence.

Terminal activity is uncertain without a configured repository context.
Parallels is uncertain without guest detail. A future Windows guest observation
supersedes generic Parallels host activity to prevent double counting. Calendar
events are context only: `LOUNAS` is break intent, and a blocking 08:00-08:45
event is a focus/reservation block rather than meeting proof. Long idle is
uncertain—not non-work—unless lock, sleep, or a manual break provides evidence.

Raw observations and derived intervals are separate SQLite tables so rules can
be changed and history recomputed. Local and server summaries clip intervals to
the requested calendar day, including intervals crossing midnight. Tracking
runs continuously; there is no office-hours gate.

## Launch at login

The menu's **Enable launch at login** action uses `SMAppService.mainApp`.
Registration requires a normally bundled/signed app (for example, open the
Swift package in Xcode, select `WorkloggerApp`, then archive/export it into
`/Applications`). It is not expected to register a transient `swift run`
executable. Continuous collection starts when the app launches.

## Project map

- `Sources/WorkloggerApp` — SwiftUI `MenuBarExtra` and controls.
- `Sources/WorkloggerCore` — models, collectors, classifier, SQLite, privacy,
  sync, and future provider protocols.
- `Tests/WorkloggerCoreTests` — classifier, privacy, and midnight-split tests.
- `server` — typed ingestion API, PostgreSQL migration, and service tests.
- `docs/PRIVACY.md` — enforceable collection and synchronization boundary.
- `docs/INTEGRATIONS.md` — future Windows, shell, browser, and calendar contracts.

## Known MVP limitations

- No Microsoft Graph/calendar ingestion.
- No Windows guest helper, shell hook, or browser adapter is shipped yet; only
  their narrow interfaces and precedence rules exist.
- `swift run` is suitable for development, but login registration needs a
  bundled app.
- The API has no authentication because it is deliberately loopback-only.
  Do not change the bind address without adding authentication and TLS.
