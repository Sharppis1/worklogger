# Future integration contracts

The MVP defines narrow providers but intentionally does not install account,
guest, shell, or browser integrations.

## Windows 11 guest in Parallels

Implement `WindowsGuestObservationProviding` with a local authenticated channel
(for example, a guest helper sending signed events over a host-only socket).
Allowed fields are timestamp, application identity, optional configured work
topic, and source. Never send window titles or document contents.

Precedence is mandatory:

1. Active manual correction.
2. Windows guest detail.
3. Generic Parallels host observation.

When guest detail exists for an interval, it replaces—not supplements—the
Parallels host interval. This prevents double counting. Missing or stale guest
detail leaves Parallels as **Uncertain**.

## Shell repository context

Implement `RepositoryContextProviding` as an explicit shell hook that reports
only the repository's configured logical name (`digitie`, `mfiles`,
`jira-modules`, or `sparx`) and a timestamp. Do not report the working
directory, command line, arguments, output, branch, remote URL, or file names.
Terminal foreground activity remains **Uncertain** until a fresh configured
repository event is available.

## Browser context

An opt-in adapter may report only the active tab's normalized host at sampling
time. It must not report paths, query strings, titles, history, or inactive
tabs. Match hosts with `HostRule`: exact equality by default, or exact
dot-delimited subdomains only when `includeSubdomains` is true.

## Calendar

Implement `CalendarIntentProviding` later, with category-level event metadata
rather than body, attendee, or location content. Calendar is intent/context and
never sufficient work proof. `LOUNAS` is break intent; the 08:00-08:45 blocking
pattern is focus/reservation context and not a meeting.
