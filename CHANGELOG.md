# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries for unreleased work are not written here directly. Each issue drops a
fragment in [`changelog.d/`](changelog.d/README.md); the fragments are assembled
into a version section at release. See that README for the format and for when a
change warrants an entry at all.

## [0.3.0] 2026-09-01

Minor release: the bridge now covers the family sibling packages.

### Added

- Adds `OpentelemetryStatifier.Persistence.setup/0,1`, bridging the fourteen
  `[:statifier_persistence, ...]` events into a `statifier_persistence.run.step`
  span with the storage, lock and lifecycle detail inside it.
- Adds `OpentelemetryStatifier.Oban.setup/0,1`, bridging the eleven
  `[:statifier_oban, ...]` events: scheduling events onto the macrostep span
  that armed them, and each delivery event as its own span linked to the
  arming trace through `caller_context`.

### Changed

- A macrostep span now nests inside the `statifier_persistence.run.step` span
  around it, instead of always rooting its own trace. With no sibling setup
  attached, nothing changes.

## [0.2.0] 2026-09-01

Minor release: the bridge tracks the statifier 2.4 line.

### Changed

- The `statifier` requirement moves from `~> 2.0` to `~> 2.4`, the release
  whose published guides carry the design this bridge implements. Anyone
  reading the engine's `docs/opentelemetry.md` alongside the bridge now
  reads the version the bridge is built and tested against.

## [0.1.2] 2026-08-27

Patch release: refreshes the published documentation with worked examples.
No code changes.

### Changed

- README gains a worked card-authorization example - chart, setup, the four
  macrostep spans it exports, and an invoke handler for `myapp:authorize` -
  plus a signup-wizard A/B example showing why chart vocabulary lands in
  attributes rather than span names. Every snippet is executed by the suite.

## [0.1.1] 2026-08-24

Patch release: brings the published documentation to the shared statifier
docs standard. No code changes.

### Changed

- The hexdocs no longer publish the repo's ADRs, and `mix docs` completes
  with zero warnings (CHANGELOG.md is on the undefined-reference skip list
  for its changelog.d link).
- README gains the standard badge row (CI, hex.pm version and downloads,
  hex docs, license), and the License section links to the LICENSE file by
  absolute GitHub URL so the link also works on hexdocs.

## [0.1.0] 2026-08-22

First release: the OpenTelemetry bridge for the
[statifier](https://hex.pm/packages/statifier) statechart engine, built on
its public `:telemetry` events only. A statechart macrostep is a span;
effect and trace telemetry events are span events on it; each macrostep
roots its own trace, stitched to its neighbors with span links. The design
is recorded upstream in statifier-ex's `docs/opentelemetry.md` and
st-ADR-0062.

### Added

- `OpentelemetryStatifier.setup/1`, which attaches the bridge to
  statifier's session telemetry and emits a `statifier.macrostep` span per
  macrostep.
- Records the effect, trace, `:interpret`, `:unroutable`, and `:halt`
  telemetry events as span events on the open macrostep span, and links
  each macrostep span to the session's previous macrostep and (for an
  invoked child's `:initialize` macrostep) to the invoking parent's open
  span. Datamodel values are excluded unless `setup/1` receives
  `record_datamodel_values: true`.
- Cleans up the span table over the session lifecycle: `:terminate`
  removes the session's rows (ending a still-open macrostep span with an
  error status), and a periodic sweep does the same for sessions whose
  process died without a `:terminate`, so a brutal kill orphans no open
  span and leaks no rows. With `trace: false` the bridge degrades to
  macrostep-grained spans with effect-level span events, no
  configuration needed.
