# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries for unreleased work are not written here directly. Each issue drops a
fragment in [`changelog.d/`](https://github.com/riddler/opentelemetry_statifier/blob/v0.9.1/changelog.d/README.md); the fragments are assembled
into a version section at release. See that README for the format and for when a
change warrants an entry at all.

## [0.9.1] 2026-10-05

Patch release: documentation only. No module, function, event or attribute
changes; the published docs gain two pages, a sidebar grouped by kind of
page, and a README rewritten as an introduction.

### Added

- A how-to guide, "How to see a chart execution as a trace", published in the docs and shipped in the package: find one chart execution in a tracing backend, follow its macrostep spans by their links, and read a macrostep's span events.
- An explanation page, "Why spans and links are shaped this way", published in the docs and shipped in the package: why each macrostep is one span and the root of its own trace, and why links stitch an execution together.

### Changed

- The HexDocs sidebar groups the extra pages by kind of page, under "How-to guides" and "Explanation".
- The README is rewritten as an introduction: what the package is, why it exists, the install pin, one basic-usage example of a library loan with the spans it exports, and a Documentation map grouped by Learn, Do, Look up and Understand. The longer integration walkthroughs it carried now live behind links to the module pages that document them.

## [0.9.0] 2026-09-28

Minor release: the persistence bridge exports `statifier_persistence`'s
batch migration span, so a `migrate_batch/3` call becomes one span carrying
the report's counts, with the spans and migrated events of the executions
it moves nested inside it.

### Added

- `OpentelemetryStatifier.Persistence` bridges `statifier_persistence`'s batch migration span: a `migrate_batch/3` call becomes a `statifier_persistence.execution.migrate_batch` span carrying the report's counts as attributes, and each execution it moves lands on it as a `migrated` span event.

### Changed

- Inside a `statifier_persistence` `migrate_batch/3` call, the `statifier_persistence.execution.lock` and `statifier_persistence.adapter.call` spans each execution's turn opens now nest under the batch span, where they were the roots of their own traces, and each migrated execution is a `migrated` span event on the batch span, where it was a zero-duration root span of its own.

## [0.8.0] 2026-09-27

Minor release: the Oban bridge covers `statifier_oban` 0.15's deferred invoke
event, a step that raises records an `exception` span event, and the
migrated point's `statifier_persistence.dropped` attribute becomes a sorted
string array, absent when a migration drops no state - a host that reads
`dropped` changes how it reads it.

### Added

- `OpentelemetryStatifier.Oban` bridges `[:statifier_oban, :invoke, :deferred]`,
  the event `statifier_oban` 0.15 emits when an invoke handler defers its
  answer: it becomes a `statifier_oban.invoke.deferred` span of its own,
  like the other delivery-seam events, and is the last span this bridge
  produces for that invocation.
- A `statifier_persistence` step that raises, throws or exits now records an
  `exception` span event on its step span, carrying `exception.type` and the
  narrowed frames as `exception.stacktrace`, so a tracing backend's exception
  view shows the failure.

### Changed

- The `statifier_persistence.dropped` attribute of a migration's
  `statifier_persistence.execution.migrated` point is now a sorted string
  array of the dropped state ids, as `statifier.configuration` is, instead of
  one `inspect/1` string; a host that parsed or matched that string queries
  the array's elements instead.
- A migration that drops no state carries no `statifier_persistence.dropped`
  attribute, because the OpenTelemetry API refuses an empty array; it carried
  the string `"[]"` before, so a host that matched that string checks for the
  attribute's absence instead.

## [0.7.0] 2026-09-26

Minor release: the persistence bridge covers the four events
`statifier_persistence` 0.19 added, so
`OpentelemetryStatifier.Persistence.events/0` names four more.

### Added

- `OpentelemetryStatifier.Persistence` bridges the four events
  `statifier_persistence` 0.19 emits that it did not: a step that raised,
  threw or exited closes its `statifier_persistence.execution.step` span
  with an error status, an `error.communication` re-entry lands as a
  `statifier_persistence.execution.step.reentered` span event on the step
  span, and an execution migrated or unparked becomes a point like the
  other lifecycle events.

## [0.6.0] 2026-09-13

Minor release: the bridge follows `statifier_persistence`'s execution rename.
The step span is now `statifier_persistence.execution.step` and the bridge
subscribes to the `[:statifier_persistence, :execution, ...]` events, so the
durable floor moves to `statifier_persistence` 0.12.

### Changed

- **Breaking for `OpentelemetryStatifier.Persistence` span names.**
  `statifier_persistence` retired `run` as the noun naming the durable
  record (its ADR-0011), so the bridge moves to the `:execution` event
  prefix in lockstep: the step span is now
  `statifier_persistence.execution.step` (was
  `statifier_persistence.run.step`), the lock span is
  `statifier_persistence.execution.lock`, and the lifecycle point spans
  are `statifier_persistence.execution.created` / `.terminated` /
  `.discarded`. `statifier_persistence.adapter.call`,
  `.identity.refused`, `.effect.failed`, `.drive.turns_exhausted` and
  the `.child.*` seam keep their names. The `run_id`-shaped metadata
  keys arrive as `execution_id`, `parent_execution_id` and
  `child_execution_id`, so the attributes they become are
  `statifier_persistence.execution_id` and friends. Update saved
  queries, dashboards and alerts that name the old spans or attributes.
- The durable floor is **`statifier_persistence` 0.12**: there is no dual
  emit upstream, so below 0.12 the six renamed event names are attached to
  names that release does not emit and the spans they carry simply stop -
  no `statifier_persistence.execution.step`, no `.execution.lock`, and no
  `.execution.created` / `.terminated` / `.discarded`. Upgrade
  `statifier_persistence` and this package together.
- Below that floor the ten names that did not move still arrive and still
  become spans, in two shapes. The nine point events - `identity.refused`,
  `effect.failed`, `drive.turns_exhausted` and the six `child.*` events -
  land as unparented root spans instead of as span events on the step.
  `adapter.call` is not one of them: it carries a `duration`, so it is
  always a span of its own back-dated by that duration, nested in the step
  span when one is open and a root when none is - except that a host which
  declared its own span through `OpentelemetryStatifier.Parent.register/2`
  still parents it, which the nine point events do not read. The other two
  families (`OpentelemetryStatifier.setup/1`'s statechart events and
  `OpentelemetryStatifier.Oban`) are unaffected.
- `OpentelemetryStatifier.Persistence.events/0` returns **16** names,
  not 14: `[:statifier_persistence, :child, :recorded]` and
  `[..., :child, :settled]` are bridged. They were added upstream after
  `statifier_persistence` 0.5.0 and had gone unbridged because this
  package's drift check was pinned to that release.

## [0.5.0] 2026-09-06

Minor release: the bridge now covers `statifier_oban`'s fan-out events, so a
chunk child's spans are reachable from the dispatch that planned them. The
test-only `statifier_oban` requirement moves to `~> 0.9`, because the fan-out
events this release bridges are 0.9.0's.

### Added

- `OpentelemetryStatifier.Oban` bridges `statifier_oban`'s three fan-out
  events. `invoke.fan_out` and `invoke.child_started` become roots linked
  to the trace that planned the invocation, so every chunk child is
  reachable from the parent's dispatch by a link edge rather than only by
  a shared `statifier.session_id`; `invoke.unstarted_cancelled` carries no
  caller context and lands as a span event on the span open where the
  sweep ran, putting its count in the trace either way.

## [0.4.1] 2026-09-06

Patch release: an Oban scheduling point emitted under a durable driver now
lands on the step span open in the emitting process instead of rooting a
trace of its own.

### Changed

- 2026-09-06: corrects the 0.3.0 entry for `OpentelemetryStatifier.Oban.setup/0,1`.
  A scheduling event lands on the macrostep span that armed it when the session
  is stepping in the emitting process, and on the step span open there under a
  durable driver.

### Fixed

- A `statifier_oban` scheduling event now falls back to the step span open in
  the emitting process when `scope` is a host's durable run id, instead of
  rooting a trace of its own.

## [0.4.0] 2026-09-02

Minor release: a host with its own durable stepper can now declare the
parent span, and a subscriber can resolve an open macrostep span by key.

### Added

- `OpentelemetryStatifier.Parent.register/2`, `unregister/1` and `within/3`
  let a host with its own durable stepper declare the span its macrostep
  spans nest inside, the way `statifier_persistence`'s step span already
  does.
- `OpentelemetryStatifier.SpanContext.lookup/2` resolves the open macrostep
  span for a `(session_id, macrostep)` pair to its W3C trace and span ids, so
  a `statifier_ui` subscriber can be wired to it as an `:otel_context`
  producer directly.

### Fixed

- The macrostep span now carries `statifier.driver`, so a backend can tell a
  durable macrostep from a session-hosted one.

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
