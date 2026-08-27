# OpentelemetryStatifier

[![CI](https://github.com/riddler/opentelemetry_statifier/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/riddler/opentelemetry_statifier/actions/workflows/ci.yml)
[![Hex.pm Version](https://img.shields.io/hexpm/v/opentelemetry_statifier.svg)](https://hex.pm/packages/opentelemetry_statifier)
[![Hex Downloads](https://img.shields.io/hexpm/dt/opentelemetry_statifier.svg)](https://hex.pm/packages/opentelemetry_statifier)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/opentelemetry_statifier/)
[![License](https://img.shields.io/hexpm/l/opentelemetry_statifier.svg)](https://github.com/riddler/opentelemetry_statifier/blob/main/LICENSE)

OpenTelemetry instrumentation for the
[Statifier](https://github.com/riddler/statifier-ex) family of statechart
packages - in the `opentelemetry_oban` / `opentelemetry_ecto` mold: the
libraries emit `:telemetry` events, this package turns them into
OpenTelemetry spans, span events, and span links. It depends only on
`opentelemetry_api`; hosts bring their own SDK and exporter.

**Status: the bridge is complete and published; the surface is small and
still pre-1.0.** `setup/1` attaches to every event
`Statifier.Session.Telemetry.events/0` names - 27 of them, against
statifier 2.x. A macrostep's
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

## A worked example: card authorization

A card-authorization state chart, the kind of flow the family uses as one
of its two canonical examples. It moves `idle -> authorizing -> authorized
-> captured`, logs on entry to `authorizing`, and reaches a final state:

```xml
<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
  <state id="idle">
    <transition event="authorize.requested" target="authorizing"/>
  </state>
  <state id="authorizing">
    <onentry>
      <log label="card" expr="'authorizing'"/>
    </onentry>
    <transition event="authorization.approved" target="authorized"/>
    <transition event="authorization.declined" target="declined"/>
  </state>
  <state id="authorized">
    <transition event="capture.requested" target="captured"/>
  </state>
  <final id="captured"/>
  <final id="declined"/>
</scxml>
```

Attach the bridge once, then run the chart exactly as you would without it -
the bridge is entirely out of the calling path:

```elixir
:ok = OpentelemetryStatifier.setup()

{:ok, machine} = Statifier.compile(chart_source)
{:ok, session} = Statifier.Session.start_link(machine, session_id: "sess_card")

:ok = Statifier.Session.send_event(session, "authorize.requested")
:ok = Statifier.Session.send_event(session, "authorization.approved")
:ok = Statifier.Session.send_event(session, "capture.requested")

# send_event/2 is a cast; status/1 is a call on the same process, so it
# serializes behind all three sends.
%{status: :done, configuration: configuration} = Statifier.Session.status(session)
```

That run exports **four** `statifier.macrostep` spans, one per macrostep -
never one per state, and never one for the session:

| Span | Key attributes | Span events | Links |
|---|---|---|---|
| boot | `trigger=initialize`, `outcome=quiescent`, `configuration=["idle"]`, `macrostep=1` | `statifier.effect.datamodel_init` | none |
| authorize | `trigger=event`, `event_name=authorize.requested`, `configuration=["authorizing"]` | `statifier.effect.log` | previous macrostep |
| approve | `trigger=event`, `event_name=authorization.approved`, `configuration=["authorized"]` | none | previous macrostep |
| capture | `trigger=event`, `event_name=capture.requested`, `outcome=done`, `macrostep=4` | `statifier.halt`, `statifier.effect.done` | previous macrostep |

The `<log>` element's span event carries the mapping rules in miniature:

```
statifier.effect.log
  statifier.label         "card"
  statifier.session_id    "sess_card"
  statifier.macrostep     2
  statifier.microstep     1
  statifier.round         0
  statifier.source.line   7
  statifier.source.column 7
```

`statifier.source.line`/`.column` are the flattened
`%Statifier.Parser.Location{}` of the `<log>` element in the source, so a
span event points at the line of SCXML that produced it. Note what is
*not* there: the raw `Statifier.Effect.Log` struct is never serialized.

### Invoking an authorization service

Registering an invoke handler is per session, through `:invoke_handlers`
(st-ADR-0051) - the registered type set is derived from the map's keys, so
registration and dispatch cannot diverge:

```xml
<state id="authorizing">
  <invoke id="auth" type="myapp:authorize"/>
  <transition event="done.invoke.auth" target="authorized"/>
</state>
```

```elixir
defmodule MyApp.AuthorizeHandler do
  @behaviour Statifier.Invoke.Handler

  # start/2, cancel/2 and forward/3 are the pure planning half: no I/O, no
  # process, no clock. They return instructions.
  @impl true
  def start(invoke, _ctx), do: {:ok, [{:handler, __MODULE__, {:authorize, invoke.invoke_id}}]}

  @impl true
  def cancel(_invoke_id, _ctx), do: {:ok, []}

  @impl true
  def forward(_invoke_id, _event, _ctx), do: {:ok, []}

  # perform/2 is the impure half. It receives the *payload* of the
  # instruction, and may be called more than once for the same invoke id -
  # so it must be idempotent.
  @impl true
  def perform({:authorize, invoke_id}, _ctx) do
    MyApp.Gateway.authorize_async(invoke_id)
    :ok
  end
end

{:ok, session} =
  Statifier.Session.start_link(machine,
    session_id: "sess_card",
    invoke_handlers: %{"myapp:authorize" => MyApp.AuthorizeHandler}
  )
```

When the gateway answers, the host tells the owning session:

```elixir
:ok = Statifier.Session.done_invocation(session, "auth", %{"code" => "approved"})
```

In the trace, the invocation is two span events on two different macrostep
spans, not a span of its own: `statifier.effect.invoke` (with
`statifier.invoke_id`, `statifier.invoke_index`, `statifier.state_index`,
and the source location) on the macrostep that entered `authorizing`, and
`statifier.effect.cancel_invoke` on the macrostep that left it. The
gateway call itself is the host's own instrumentation to span - this
bridge reports what the chart did, not what the handler did.

## The second canonical domain: a signup wizard with A/B variants

The other example domain the family uses is a signup wizard with A/B
testing, and it is the clearest way to see the cardinality policy:

```xml
<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="assigning">
  <state id="assigning">
    <transition event="variant.a.assigned" target="plan_a"/>
    <transition event="variant.b.assigned" target="plan_b"/>
  </state>
  <state id="plan_a">
    <transition event="signup.completed" target="converted"/>
  </state>
  <state id="plan_b">
    <transition event="signup.completed" target="converted"/>
  </state>
  <final id="converted"/>
</scxml>
```

Both variants produce spans named `statifier.macrostep` - the variant
shows up as `statifier.event_name` (`"variant.a.assigned"`) and in
`statifier.configuration` (`["plan_a"]`), never in the span name. Span-name
cardinality is one for every chart in the family, so a backend that keys on
span name sees one operation, and a query that splits conversion by variant
filters on the attribute. Chart vocabulary is data.

The same rule is why the two datamodel events are recorded *without* their
values by default: a signup wizard's datamodel holds whatever the host put
there, which is unbounded by definition. Opt in per setup, deliberately:

```elixir
:ok = OpentelemetryStatifier.setup(record_datamodel_values: true)
```

Every snippet and span shape on this page is executed by
`test/opentelemetry_statifier/readme_example_test.exs` against a real
session, so a README that drifts from the library fails the gate.

## License

MIT - see
[LICENSE](https://github.com/riddler/opentelemetry_statifier/blob/main/LICENSE).
