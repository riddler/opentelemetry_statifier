# OpentelemetryStatifier

OpenTelemetry instrumentation for the
[Statifier](https://github.com/riddler/statifier-ex) family of statechart
packages - in the `opentelemetry_oban` / `opentelemetry_ecto` mold: the
libraries emit `:telemetry` events, this package turns them into
OpenTelemetry spans, span events, and span links. It depends only on
`opentelemetry_api`; hosts bring their own SDK and exporter.

**Status: early implementation.** `setup/1` attaches to every event
`Statifier.Session.Telemetry.events/0` names. A macrostep's
`:start`/`:stop` pair becomes one `statifier.macrostep` span; everything
that fires in between - the eleven effect events, the nine trace events,
`:interpret`, `:unroutable`, `:halt` - becomes a span event on it, and
each span links to the same session's previous macrostep and (for an
invoked child's `:initialize` macrostep) to the invoking parent's open
span. `:terminate` cleans up the session's rows, and a periodic sweep
ends the spans a brutally killed session orphans with an error status
rather than leaking them. The design this package implements is
recorded in statifier-ex:

- [`docs/opentelemetry.md`](https://github.com/riddler/statifier-ex/blob/main/docs/opentelemetry.md) -
  span topology, context propagation, attribute mapping, cardinality
  policy, and trace-off degradation.
- [st-ADR-0062](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0062-opentelemetry-bridge-is-a-separate-package.md) -
  packaging and scope: family-scoped and public-events-only. (Its
  unpublished-until-statifier-ships clause is resolved: statifier 2.0.0 is
  on Hex, st-ADR-0066, and so is this package.)

The short version of the design: a statechart macrostep is a span; effect
and trace telemetry events are span events on it; there is no
session-lifetime span; each macrostep roots its own trace, stitched to its
neighbors (previous macrostep, invoking parent) with span links; nothing
unbounded is exported as an attribute by default.

## Installation

```elixir
def deps do
  [
    {:opentelemetry_statifier, "~> 0.1"}
  ]
end
```

The library depends only on `opentelemetry_api`; your host brings the
`opentelemetry` SDK and exporter it actually ships.

## Usage

Call `setup/0` (or `setup/1` with options) once, typically at application
start, after your host has configured its own OpenTelemetry SDK and
exporter:

```elixir
:ok = OpentelemetryStatifier.setup()

# or, with options:
:ok = OpentelemetryStatifier.setup(record_datamodel_values: false)
```

This attaches a handler to every event the statifier telemetry contract
emits. Each statechart macrostep becomes a `statifier.macrostep` span,
carrying `statifier.session_id`, `statifier.trigger`, `statifier.outcome`,
and the macrostep's counters and resulting configuration as attributes.
The effect and trace events that fire inside the macrostep land on the
span as span events (`statifier.effect.send`, `statifier.trace.exit_set`,
...), attributes mapped uniformly under the `statifier.` namespace: a
resolved source location flattens to
`statifier.source.line`/`statifier.source.column`, a configuration
becomes a sorted string array, and the raw effect struct is never
serialized. The two events that carry datamodel values
(`:datamodel_change`, `:datamodel_init`) are recorded *without* those
values unless you opt in with `record_datamodel_values: true` - nothing
unbounded is exported by default.

Each macrostep span is the root of its own trace. Span links stitch the
traces together: every macrostep links to the same session's previous
macrostep span, and an invoked child session's `:initialize` macrostep
links to the parent macrostep span that was open when the child started.

Call `teardown/0` to detach everything, for example between test cases:

```elixir
:ok = OpentelemetryStatifier.teardown()
```

With no SDK started, the bridge is a cheap no-op: spans go through a
no-op tracer and nothing is exported.

### The `:initialize` macrostep span starts late

Span start times come from the telemetry event's own `monotonic_time`, so
for an `event`-triggered macrostep the span's wall time matches the
`statifier.duration` measurement almost exactly. The `:initialize`
macrostep is the one documented exception: statifier emits its `:start`
from the session's `init/1` and its `:stop` from the following
`handle_continue`, so the span opens after some of the work it covers has
already happened. The span is correspondingly shorter than
`statifier.duration` reports - materially so, not by a rounding margin.

This skew is accepted rather than corrected: the alternative is
back-calculating the start from `end_time - duration`, which every other
bridge in the family does for *every* span and which is strictly less
accurate for the other triggers. Read `statifier.duration`, not the span's
wall time, when you want the macrostep's real cost.

## License

MIT - see [LICENSE](LICENSE).
