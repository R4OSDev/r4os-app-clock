# CLOCK.R4X

`CLOCK.R4X` is an independent R4OS application implemented in Zig.

## Package

- Version: `0.1.10`
- Image target: `/R4OS/SOFTWARE/DESKTOP/CLOCK.R4X`
- Image scope: `full`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

## Runtime

The hosted clock waits through the shared desktop event loop. A one-second
timer obtains one validated `TIMESVC` snapshot through a persistent service
connection; change detection and every redraw reuse that same snapshot.
Resize and other redraw-only events therefore do not issue another service
request. If `TIMESVC` is unavailable, the clock keeps the local `R4STD`
timezone fallback and retries at most once per timer cycle.

`/BENCHMARK` runs the hosted path for ten seconds. `/GUI` adds a 100 ms
minimum-size change source that produces real resize events; `/RECOVERY`
performs one controlled `TIMESVC` stop/start during the run. Each invocation
emits and appends one numeric `CLOCKPERF|2` row to
`D:\CLOCKPERF.TXT` on the writable benchmark data volume. Its fields after
the schema version are: phase,
duration, runtime ticks, event frequency; wait calls, second/load timer wakes,
GUI wakes, wait failures and missed periods; timer-lateness count,
minimum/p50/p95/p99/maximum/mean; initial/second/fallback-wait samples;
service calls/successes/failures, open attempts/successes, reconnects, close
attempts/successes and fallback samples; render attempts/presented frames and
second/format/zone changes; remote status samples, first/last counter,
accumulated delta and resets; phase actions/failures, recovery stop/start
results and final service-source flag.

`/SELFTEST` also exercises a controlled service stop, local fallback, stale
connection invalidation, service restart and bounded reconnection. It restores
`TIMESVC` before returning.

## Build

On Windows:

    Build.bat

On Linux or macOS:

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.

API migration 0.90.68
---------------------
The normal SDK201/Contract93/Libraries57 build selects App2 and platform
Query2 plus the technical R4STD Query2 entry. TIME_V1 retains its library ABI.
The shared argument cursor reads the whole argument string. Clock requests
use ServiceConnection with a checked absolute budget and publish only an
exact validated reply. Absolute timer deadlines use the canonical rebased
ticks provider. Clock samples validate identity, frequency and forward time.
A changed/unavailable clock or wait failure ends the caller with its error.
TIME.R4S reads bind full metadata. Font changes rebuild layout and Canvas.
