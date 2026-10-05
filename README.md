# OpentelemetryStatifier

[![CI](https://github.com/riddler/opentelemetry_statifier/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/riddler/opentelemetry_statifier/actions/workflows/ci.yml)
[![Hex.pm Version](https://img.shields.io/hexpm/v/opentelemetry_statifier.svg)](https://hex.pm/packages/opentelemetry_statifier)
[![Hex Downloads](https://img.shields.io/hexpm/dt/opentelemetry_statifier.svg)](https://hex.pm/packages/opentelemetry_statifier)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/opentelemetry_statifier/)
[![License](https://img.shields.io/hexpm/l/opentelemetry_statifier.svg)](https://github.com/riddler/opentelemetry_statifier/blob/main/LICENSE)

OpenTelemetry spans and links for chart executions. The
[Statifier](https://github.com/riddler/statifier-ex) family emits
`:telemetry` events as a chart executes; this package turns them into
spans, span events and span links, in the `opentelemetry_oban` and
`opentelemetry_ecto` mold. It depends only on `opentelemetry_api`: your host
brings the SDK and the exporter.

## Why this package

A chart execution moves through states on events that arrive minutes or days
apart, often on different processes and nodes, and the family reports each
step as plain `:telemetry` events. Without a bridge, a trace shows the HTTP
request or the job that delivered an event and nothing of what the chart did
with it, and the events are left for you to pair, nest and correlate by
hand. With this package attached, every macrostep (one event taken to rest)
is a `statifier.macrostep` span, what happened inside it lands on that span
as span events, and links stitch each macrostep to the previous one and to
the parent that invoked it, so an execution reads as a chain of traces you
can follow. Span names stay fixed whatever the chart's vocabulary, and
nothing unbounded, such as a datamodel value, becomes an attribute unless
you ask for it.

## Install

Add `opentelemetry_statifier` to the dependencies in your `mix.exs`:

```elixir
def deps do
  [
    {:opentelemetry_statifier, "~> 0.9.0"}
  ]
end
```

Your host keeps its own `opentelemetry` SDK and exporter configuration; the
bridge sends spans through whatever tracer provider is running.

## Basic usage

A library loan: a copy of a book is checked out to a patron, renewed once
before it falls due, and returned. Attach the bridge once, at application
start, after your host has started its OpenTelemetry SDK; then execute the
chart exactly as you would without it, since the bridge is out of the calling
path:

```elixir
:ok = OpentelemetryStatifier.setup()

chart_source = """
<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="on_shelf">
  <state id="on_shelf">
    <transition event="loan.checked_out" target="on_loan"/>
  </state>
  <state id="on_loan">
    <onentry>
      <log label="loan" expr="'on loan'"/>
    </onentry>
    <transition event="loan.renewed" target="on_loan"/>
    <transition event="loan.returned" target="returned"/>
    <transition event="loan.lost" target="lost"/>
  </state>
  <final id="returned"/>
  <final id="lost"/>
</scxml>
"""

{:ok, machine} = Statifier.compile(chart_source)
{:ok, session} = Statifier.Session.start_link(machine, session_id: "loan_42")

:ok = Statifier.Session.send_event(session, "loan.checked_out")
:ok = Statifier.Session.send_event(session, "loan.renewed")
:ok = Statifier.Session.send_event(session, "loan.returned")

# send_event/2 is a cast; status/1 is a call on the same process, so it
# answers after all three events are taken.
%{status: :done} = Statifier.Session.status(session)
```

That execution exports four `statifier.macrostep` spans, one per macrostep:
never one per state, and never one for the session.

| Span | Key attributes | Span events | Links |
|---|---|---|---|
| start | `trigger=initialize`, `outcome=quiescent`, `configuration=["on_shelf"]`, `macrostep=1` | `statifier.effect.datamodel_init` | none |
| check out | `trigger=event`, `event_name=loan.checked_out`, `configuration=["on_loan"]` | `statifier.effect.log` | previous macrostep |
| renew | `trigger=event`, `event_name=loan.renewed`, `configuration=["on_loan"]` | `statifier.effect.log` | previous macrostep |
| return | `trigger=event`, `event_name=loan.returned`, `outcome=done`, `macrostep=4` | `statifier.halt`, `statifier.effect.done` | previous macrostep |

Every attribute sits under the `statifier.` namespace
(`statifier.session_id` is `"loan_42"` on all four), and the `<log>` span
event carries `statifier.source.line` and `statifier.source.column`, so it
points at the line of the chart that produced it. Why the state and event
names are attributes rather than span names is in
[Why spans and links are shaped this way](docs/explanation/why-spans-and-links-are-shaped-this-way.md).
An `<invoke>`, such as a check for holds on the copy
before it goes out, shows up the same way: a `statifier.effect.invoke` span
event on the macrostep that entered the invoking state, and
`statifier.effect.cancel_invoke` on the one that left it; the invoked work
itself is yours to span. The first span opens late: the session emits the
`:initialize` macrostep's start after some of its work is done, so read
`statifier.duration` rather than that span's wall time for its real cost.
Call `OpentelemetryStatifier.teardown/0` to detach the bridge.

## Documentation

- Learn
  - [Basic usage](#basic-usage): a loan executed with the bridge attached, and the four spans it exports.
- Do
  - [See a chart execution as a trace](docs/guides/how-to-see-a-chart-execution-as-a-trace.md): find one loan's execution in your tracing backend and follow its macrosteps from the first to the last.
  - [Trace the durable stepper's storage phases](https://hexdocs.pm/opentelemetry_statifier/OpentelemetryStatifier.Persistence.html): the step span the macrosteps nest inside, and the batch migration span, in the API reference until a guide page exists.
  - [Trace delayed sends and invocations that ride Oban jobs](https://hexdocs.pm/opentelemetry_statifier/OpentelemetryStatifier.Oban.html): which events land on the macrostep span and which become their own linked spans, in the API reference until a guide page exists.
  - [Nest macrosteps under your own durable stepper's span](https://hexdocs.pm/opentelemetry_statifier/OpentelemetryStatifier.Parent.html): the scoped `within/3`, or `register/2` and `unregister/1`, in the API reference until a guide page exists.
  - [Stamp trace ids onto a statifier_ui trace stream](https://hexdocs.pm/opentelemetry_statifier/OpentelemetryStatifier.SpanContext.html): the lookup to hand the subscriber as its `:otel_context` producer, in the API reference until a guide page exists.
- Look up
  - [setup/1](https://hexdocs.pm/opentelemetry_statifier/OpentelemetryStatifier.html#setup/1): what attaching does, and what an invalid option returns.
  - [The attribute mapping](https://hexdocs.pm/opentelemetry_statifier/OpentelemetryStatifier.Attributes.html): how each measurement and metadata key becomes an attribute, and what is never exported.
  - [The changelog](https://github.com/riddler/opentelemetry_statifier/blob/main/CHANGELOG.md): what changed in each version.
- Understand
  - [Why spans and links are shaped this way](docs/explanation/why-spans-and-links-are-shaped-this-way.md): why each macrostep is one span and the root of its own trace, why links join macrosteps rather than parents, and the alternatives that lost.
  - [What the bridge produces](https://hexdocs.pm/opentelemetry_statifier/OpentelemetryStatifier.html): spans, span events and links for each macrostep, cleanup after a crash, and why the first span starts late.
  - [The span design](https://github.com/riddler/statifier-ex/blob/main/docs/opentelemetry.md): span topology, context propagation, attribute mapping, the cardinality policy and trace-off degradation, recorded in statifier-ex.
  - [The decision records](https://github.com/riddler/opentelemetry_statifier/tree/main/docs/adr): why the handler attaches per event, how the span table works, and why the sibling bridges are separate setup calls.

## Compatibility

The package needs Elixir 1.18 or later (`elixir: "~> 1.18"` in `mix.exs`).
Its runtime dependencies are `statifier` `~> 2.4`, `opentelemetry_api`
`~> 1.4` and `telemetry` `~> 1.0`. The `Persistence` and `Oban` bridges take
no dependency on `statifier_persistence` or `statifier_oban`: each attaches
to the event names its own `events/0` lists.

Until 1.0, the public surface may change between minor releases: a release
may rename modules, callbacks, telemetry events or error vocabulary with no
compatibility shim. Every such change is recorded in the
[changelog](https://github.com/riddler/opentelemetry_statifier/blob/main/CHANGELOG.md)
under a bold **Breaking** heading that says what to do about it, and pinning
to an exact minor, `~> X.Y.0`, is the recommended way to take the package
until then.

## License

MIT - see
[LICENSE](https://github.com/riddler/opentelemetry_statifier/blob/main/LICENSE).
