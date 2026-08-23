# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries for unreleased work are not written here directly. Each issue drops a
fragment in [`changelog.d/`](changelog.d/README.md); the fragments are assembled
into a version section at release. See that README for the format and for when a
change warrants an entry at all.

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
