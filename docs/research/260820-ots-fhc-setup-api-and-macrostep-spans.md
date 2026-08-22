---
date: 2026-08-20T16:08:17-0600
researcher: Claude
git_commit: ca90f35e1bb4e938c2922ad1cc2a9b4cd180b10a
branch: ots-fhc-setup-macrostep-spans
repository: opentelemetry_statifier
beads_issue: ots-fhc
topic: "ots-fhc: setup/1 handler attach and macrostep spans paired on span_ref"
tags: [research, codebase, bridge, spans, telemetry]
status: complete
last_updated: 2026-08-20
last_updated_by: Claude
---

# Research: ots-fhc - setup/1 handler attach and macrostep spans paired on span_ref

**Date**: 2026-08-20T16:08:17-0600
**Git Commit**: ca90f35e1bb4e938c2922ad1cc2a9b4cd180b10a
**Branch**: ots-fhc-setup-macrostep-spans
**Bead**: ots-fhc (child of epic ots-8wp, mirrors st-cmq.2)

## Research Question

For the first implementation slice of the bridge: what exists today, in this
repository and in the upstream contract it consumes, that the following work
must be built against?

- `OpentelemetryStatifier.setup/1` attaching handlers to every name from
  `Statifier.Session.Telemetry.events/0`
- macrostep `:start` opening a `statifier.macrostep` span and the `:stop`
  whose `span_ref` matches closing it (never pairing on
  `session_id` + `macrostep`)
- `trigger` / `event_name` / `outcome` / counters as `statifier.*` attributes
- a per-session ETS table holding the open span and the last span context
- span start time taken from the event's `monotonic_time`, accepting the
  `:initialize` span's known start-time skew

And what the binding hard constraints are: public telemetry events only,
nothing unbounded reaching an attribute by default, and defensive handler
boundaries.

## Summary

This repository is a scaffold. `lib/` holds one module with a placeholder
`setup/0`; `test/` holds one test asserting it returns `:ok`. Everything
load-bearing for this bead lives upstream, and the most important finding of
this pass is **where** upstream: the two documents ADR-0002 adopts as binding
are *not present in the pinned dependency*. `deps/statifier` is pinned at
`fe77a8249f58e463c69634987ab2000101a152cf`, which predates both
`docs/opentelemetry.md` and st-ADR-0062. Both exist on the sibling checkout's
`main` at `/Users/johnnyt/repos/github/statifier-ex`, and this research read
them there.

What is in the pinned dep and is authoritative for the event shapes is
`Statifier.Session.Telemetry` - the 27-event moduledoc table, `events/0`, and
the two emitters this bead pairs.

Four facts settle most of the design questions this slice raises:

1. **`span_ref` is a plain metadata key, not `telemetry_span_context`.**
   Statifier hand-rolls its span pair rather than calling `:telemetry.span/3`
   (the reason is recorded in the moduledoc: `:telemetry.span/3` wraps its
   function in a `rescue` and always emits an `:exception` half, which this
   contract does not have). So the bridge reads `metadata.span_ref`, and it
   must expect starts that never get a stop.

2. **The units line up exactly.** The `monotonic_time` measurement on both
   halves is `System.monotonic_time/0` - Erlang native monotonic units. The
   `:start_time` key in `opentelemetry_api`'s `start_opts` is typed
   `opentelemetry:timestamp()`, which is also `erlang:monotonic_time()` in
   native units. The measurement can be passed straight through with no
   conversion.

3. **Both halves fire in the same process, synchronously.**
   `:telemetry.execute/3` is synchronous and `Statifier.Session` is a
   GenServer, so every macrostep event for a session arrives in that
   session's own process, serially. That is what makes an ETS table keyed by
   session viable, and it is also the reason the caller's OTel context is
   never ambient (the design note's session-process caveat).

4. **A handler that raises is detached from every event it attached to.**
   `:telemetry`'s `do_execute/4` catches, calls `detach(HandlerId)`, emits
   `[:telemetry, :handler, :failure]`, and logs. Under `attach_many/4` that
   detach removes the handler from *all* names in the list, so one malformed
   event would silently kill the whole bridge for the VM's lifetime.

## Detailed Findings

### This repository, as it stands

- [`lib/opentelemetry_statifier.ex:1-30`](https://github.com/riddler/opentelemetry_statifier/blob/ca90f35e1bb4e938c2922ad1cc2a9b4cd180b10a/lib/opentelemetry_statifier.ex#L1-L30) - the whole of `lib/`. A moduledoc
  pointing at the upstream design, and `setup/0` returning `:ok` with a
  doctest. There is no `setup/1`, no handler module, no ETS table, no
  attribute namespace helper. The moduledoc says "Nothing is implemented
  yet."
- [`test/opentelemetry_statifier_test.exs:1-10`](https://github.com/riddler/opentelemetry_statifier/blob/ca90f35e1bb4e938c2922ad1cc2a9b4cd180b10a/test/opentelemetry_statifier_test.exs#L1-L10) - one test, carrying the
  project's required sabotage line
  (`# sabotage: setup/0 returns :error -> red`). [`test/test_helper.exs:1`](https://github.com/riddler/opentelemetry_statifier/blob/ca90f35e1bb4e938c2922ad1cc2a9b4cd180b10a/test/test_helper.exs#L1)
  is a bare `ExUnit.start()` - no SDK wiring yet.
- [`config/test.exs:1-6`](https://github.com/riddler/opentelemetry_statifier/blob/ca90f35e1bb4e938c2922ad1cc2a9b4cd180b10a/config/test.exs#L1-L6) - `config :opentelemetry, traces_exporter: :none`,
  with the comment that "Tests that assert on spans attach their own
  in-process exporter." That decision is made but unimplemented.
- [`mix.exs:38-56`](https://github.com/riddler/opentelemetry_statifier/blob/ca90f35e1bb4e938c2922ad1cc2a9b4cd180b10a/mix.exs#L38-L56) - `{:opentelemetry_api, "~> 1.4"}` and `{:telemetry, "~> 1.0"}`
  as runtime deps; `{:opentelemetry, "~> 1.5", only: :test}`. `mix.lock`
  resolves these to `opentelemetry_api` 1.5.0 and `opentelemetry` 1.7.0.
- [`mix.exs:59-72`](https://github.com/riddler/opentelemetry_statifier/blob/ca90f35e1bb4e938c2922ad1cc2a9b4cd180b10a/mix.exs#L59-L72) - `statifier_dep/0`: `STATIFIER_PATH` overrides to a path
  dep, otherwise `{:statifier, github: "riddler/statifier-ex", branch: "main"}`.
- [`mix.exs:36`](https://github.com/riddler/opentelemetry_statifier/blob/ca90f35e1bb4e938c2922ad1cc2a9b4cd180b10a/mix.exs#L36) - `elixirc_paths(:test)` already includes `test/support`, and
  `coveralls.json` skips that directory, so a test-support exporter module has
  a home that does not count against the 90% coverage floor.
- `.quality.exs:1-33` - `compile: warnings_as_errors`, `credo: strict`, and a
  `loop` profile. No `.credo.exs` and no `.doctor.exs`: credo's `--strict`
  defaults are the gate, and there is no Doctor stage here (unlike
  statifier-ex, which enforces 100% moduledoc/doc/spec).
- `docs/adr/0001-record-architecture-decisions.md`, `docs/adr/0002-adopts-the-upstream-bridge-contract.md`,
  `docs/adr/README.md` - the entire ADR set. ADR-0002 decision 5 is the one
  this slice can violate mechanically: **`lib/` depends on
  `opentelemetry_api` only; the SDK appears in the test environment alone.**
- `docs/research/` and `docs/plans/` did not exist before this document.
  `.claude/wurk/` does not exist, so this skill has no project extension and
  the `wurk-codebase-*` agents have no orientation file.

Bead context (`bd list`): the epic is `ots-8wp`. This bead's siblings are
`ots-j82` (effect/trace events become span events; links stitch traces),
`ots-lt6` (ETS lifecycle: terminate cleanup and the orphan sweep), and
`ots-6ns` (CI). All three depend on `ots-fhc`.

### The event contract, in the pinned dependency

`deps/statifier/lib/statifier/session/telemetry.ex` is the single
authoritative reference. `events/0` (`deps/statifier/lib/statifier/session/telemetry.ex:269-273`)
returns exactly 27 names, built from three module attributes:

- `@lifecycle_events` (`:216-233` region, list at `:225-233`) - 7 names:
  `[:statifier, :session, :init | :halt | :terminate | :interpret | :unroutable]`
  plus `[:statifier, :session, :macrostep, :start]` and `[..., :stop]`.
- `@effect_kinds` (`:235-247`) - 11 kinds, mapped to
  `[:statifier, :session, :effect, kind]`.
- `@trace_kinds` (`:249-259`) - 9 kinds, mapped to
  `[:statifier, :session, :trace, kind]`.

7 + 11 + 9 = 27. `events/0` is the enumeration the bead requires `setup/1`
to attach against; the moduledoc says explicitly it exists "so a consumer can
`:telemetry.attach_many/4` to the whole surface without hand-copying names."

The two events this slice pairs:

```
| [:statifier, :session, :macrostep, :start] | system_time, monotonic_time | session_id, trigger, event_name, span_ref |
| [:statifier, :session, :macrostep, :stop]  | duration, macrostep, microsteps, rounds, monotonic_time | session_id, trigger, outcome, event_name, configuration, span_ref |
```

(`deps/statifier/lib/statifier/session/telemetry.ex:119-120`)

The emitters, verbatim:

- `macrostep_start/4` (`deps/statifier/lib/statifier/session/telemetry.ex:362-373`) -
  measurements `%{system_time: System.system_time(), monotonic_time: System.monotonic_time()}`;
  metadata `%{session_id:, trigger:, event_name:, span_ref:}`.
- `macrostep_stop/7` (`deps/statifier/lib/statifier/session/telemetry.ex:395-414`) -
  measurements `%{duration: System.monotonic_time() - start_time, macrostep:, microsteps:, rounds:, monotonic_time: System.monotonic_time()}`;
  metadata `%{session_id:, trigger:, outcome:, event_name:, configuration:, span_ref:}`.

Value domains, from the specs:

- `trigger :: :initialize | :event | :cancel | :internal | :resume`
  (`deps/statifier/lib/statifier/session/telemetry.ex:358`, `:388`). Five, not four
  - see Open Questions.
- `outcome :: :quiescent | :done | :cancelled | :budget_exhausted`
  (`deps/statifier/lib/statifier/session/telemetry.ex:391`).
- `event_name :: String.t() | nil` - `event_name/1`
  (`deps/statifier/lib/statifier/session/telemetry.ex:720-722`) returns `nil`
  for a `nil` event and `%Statifier.Event{}.name` otherwise. It is `nil` on
  every `:initialize`, `:cancel`, and `:resume` span.
- `configuration :: MapSet.t(String.t())` - already resolved to state-id
  strings by `resolve_configuration/2`
  (`deps/statifier/lib/statifier/session/telemetry.ex:713-718`), so the bridge
  needs no `Machine` handle. It is a `MapSet`, not a list; OTel string-array
  attributes need `MapSet.to_list/1`.
- `span_ref :: reference()` - `make_ref/0`, one per span.

**Why `span_ref` and not `(session_id, macrostep)`.** The moduledoc's "Span
correlation" section (`deps/statifier/lib/statifier/session/telemetry.ex:33-62`)
gives two independent reasons, and the bead restates them as a hard rule:

1. The start half deliberately carries **no** `macrostep` measurement at all.
   The counter advances *inside* the core call the span brackets, so a value
   read at start would be pre-increment and the stop's post-increment - the
   two would disagree on a pairing key. `macrostep` is authoritative only on
   the stop half.
2. ADR-0039 re-entry nests an `:internal` span inside an `:event` span
   already in flight, producing `start, start, stop, stop` on one session.
   Each span gets its own `span_ref`; nothing else disambiguates them.

The nesting is real and visible in the emitter call sites. `in_macrostep/4`
(`deps/statifier/lib/statifier/session.ex:1508-1540`) takes `start_time` and
`span_ref` into local bindings precisely because `drive.()` can re-enter and
open a nested span; its own comment says the inner call's
`%{state | macrostep_started_at: nil}` "would otherwise clobber the outer
span's start time out from under it."

**The `:initialize` span is the odd one.** Its start is emitted in `init/1`
(`deps/statifier/lib/statifier/session.ex:839-853`) - `start_time = System.monotonic_time()`
and `span_ref = make_ref()` are taken *before* `boot/6` runs, but
`Telemetry.macrostep_start/4` is only called *after* it returns. Its stop
comes from `handle_continue({:initialize, ...})`
(`deps/statifier/lib/statifier/session.ex:1196-1209`), one message-loop turn
later, carrying the same `start_time` and `span_ref` through the continue
term. So `duration` is honest but the `system_time` on the start half is
late. The moduledoc records this at `:72-78`; the design note's decision is
below.

**Unmatched starts are contract, not a bug.** The moduledoc (`:64-70`) states
there is deliberately no `:exception` member of the family, and "a subscriber
pairing on `span_ref` should not expect every `span_ref` it sees on a start to
arrive again on a stop."

### The design note - the binding mapping, read from the sibling checkout

`/Users/johnnyt/repos/github/statifier-ex/docs/opentelemetry.md` is the
st-cmq.2 design note ADR-0002 decision 3 names as governing. The parts this
slice implements:

- **Span topology** (`docs/opentelemetry.md:66-76` upstream): "the bridge
  opens a span on `:start` and closes it on the `:stop` whose `span_ref`
  matches - never by pairing on `(session_id, macrostep)`". Span name
  `statifier.macrostep`, singular. `trigger` and `event_name` are
  **attributes, not part of the name** - "event names are chart vocabulary
  and would explode the span-name cardinality backends key on."
- **No session-lifetime span** (upstream `:91-95`). `statifier.session_id` is
  an attribute on every span.
- **One trace per macrostep, stitched with links** (upstream `:97-117`). The
  bridge "holds the last-emitted span context per `session_id` in an ETS
  table it owns". The link *emission* is ots-j82; what this slice owes is the
  table slot.
- **Attribute mapping** (upstream `:136-155`): all attributes under
  `statifier.`; measurements become integer attributes of the same name;
  identity metadata (`session_id`, `event_name`, `trigger`, `outcome`, ...)
  becomes string/int attributes of the same name; `configuration` becomes a
  string-array attribute, "bounded by the chart's state count, not by runtime
  data"; and "the raw `effect` struct in every event's metadata is *not*
  serialized into attributes."
- **Failure tolerance** (upstream `:177-191`), the paragraph this bead cites
  for the skew: "The bridge sets the span start from the event's
  `monotonic_time` and accepts the skew on that one span rather than
  inventing a second clock." The same section assigns the ETS cleanup and
  orphan sweep - "an unmatched open span is ended with an error status at
  sweep time, not silently dropped" - which is ots-lt6, not this slice.
- **Cardinality** (upstream `:157-174`): "Nothing unbounded is exported by
  default", with `:datamodel_change`'s `new_value`/`prior_value` and
  `:datamodel_init`'s `datamodel` gated behind
  `record_datamodel_values: true` at setup. Those events are ots-j82's, but
  **the option they key off is parsed by `setup/1`, which is this slice's**.
- **Trace-off degradation** (upstream `:193-203`): no bridge configuration
  and no conditional - the trace family simply never reaches `:telemetry`
  under `trace: false` because `Statifier.Effect.trace/3` expands to nothing
  in the core.

st-ADR-0062's decisions (same checkout,
`docs/adr/0062-opentelemetry-bridge-is-a-separate-package.md`) are the
packaging half already adopted verbatim by this repo's ADR-0002: separate
package, ecosystem naming, family scope, public contracts structurally, git
pin, unpublished, and the 27-name freeze.

st-ADR-0040's decision section is the event contract's reasoning. Two points
matter here: `events/0` exists so a consumer can attach to everything without
copying names (its "Event names, prefix, and enumeration" subsection), and
`duration` is `:native` units "per `:telemetry`'s own convention - unit
conversion is left to the consumer" (`deps/statifier/lib/statifier/session/telemetry.ex:133-135`).

st-ADR-0061 is the SHA-pinning contract; it governs [`mix.exs:59-72`](https://github.com/riddler/opentelemetry_statifier/blob/ca90f35e1bb4e938c2922ad1cc2a9b4cd180b10a/mix.exs#L59-L72) and the
"unpublished" consequence, and this slice does not touch it.

### The `opentelemetry_api` surface actually available

Pinned at **1.5.0** (`mix.lock`), vendored at `deps/opentelemetry_api/`.

**Starting a span with an explicit start time.** The `start_opts` type is
Erlang-side, `deps/opentelemetry_api/src/otel_span.erl:47-52`:

```erlang
-type start_opts() :: #{attributes => opentelemetry:attributes_map(),
                        links => [opentelemetry:link()],
                        is_recording => boolean(),
                        start_time => opentelemetry:timestamp(),
                        kind => opentelemetry:span_kind()}.
```

Five keys, and **no `:parent` key**. Parenting is implicit: it comes from the
`Ctx` passed to the 3-arity `start_span/3`, or from the process's current ctx
for the 2-arity form. Defaults are filled by
`otel_span:validate_start_opts/1` (`deps/opentelemetry_api/src/otel_span.erl:62-75`);
unknown keys are silently ignored rather than rejected.

`opentelemetry:timestamp()` is `integer()`, and
`deps/opentelemetry_api/src/opentelemetry.erl:328-330` defines
`timestamp() -> erlang:monotonic_time().` The Elixir moduledoc for
`OpenTelemetry.timestamp/0` (`deps/opentelemetry_api/lib/open_telemetry.ex:127-140`)
says the same in words: "A monotonically increasing time provided by the
Erlang runtime system in the native time unit."

**This is the key alignment for this bead**: statifier's `monotonic_time`
measurement is `System.monotonic_time/0`, which is exactly
`erlang:monotonic_time()` in native units. It goes into `start_time:` and
into `Span.end_span/2` with no conversion. `OpenTelemetry.convert_timestamp/2`
and `timestamp_to_nano/1` (`deps/opentelemetry_api/lib/open_telemetry.ex:142-154`)
exist but are the wrong direction here - they add `erlang:time_offset()` to
produce a system time, which is what the SDK does at export.

**Macros vs functions.** Only four things in the API are macros, all in
`OpenTelemetry.Tracer`: `start_span/2` (`deps/opentelemetry_api/lib/open_telemetry/tracer.ex:28`),
`start_span/3` (`:45`), `with_span/2` (`:84`), and `with_span/3` (`:104`).
They are macros because they resolve
`:opentelemetry.get_application_tracer(__MODULE__)` at the call site's
compile-time module - which OTP application's tracer to use is picked from
`__CALLER__`, not passed in. Any module calling them needs
`require OpenTelemetry.Tracer`.

Everything else is a plain function needing no `require`: all of
`OpenTelemetry.Span`, all of `OpenTelemetry.Ctx`, all of `OpenTelemetry`, and
`Tracer.set_current_span/1,2`, `current_span_ctx/0,1`, `end_span/1`,
`set_attribute/2`, `set_attributes/1`, `add_event/2`, `set_status/1,2`
(`deps/opentelemetry_api/lib/open_telemetry/tracer.ex:61-259`).

**The ctx-explicit path is the one this bridge needs.** Every function in
`OpenTelemetry.Tracer` other than `start_span`/`with_span` operates on
`:otel_tracer.current_span_ctx()` implicitly - process-local state. The
bridge's spans are not lexically scoped: they open in one handler invocation
and close in another. `OpenTelemetry.Span` is the ctx-explicit mirror,
`deps/opentelemetry_api/lib/open_telemetry/span.ex`:

- `set_attribute(span_ctx, key, value)` (`:118-123`), returns `boolean()`
- `set_attributes(span_ctx, attributes)` (`:130-131`)
- `add_event(span_ctx, event, attributes)` (`:138-143`)
- `set_status(span_ctx, status)` (`:192-193`)
- `end_span(span_ctx)` (`:87`) and `end_span(span_ctx, timestamp)` (`:97`)
- `record_exception(span_ctx, exception, trace \\ nil, attributes \\ [])`
  (`:166-181`) - note this is an Elixir-level reimplementation over
  `add_event`, not a delegate to Erlang's `otel_span:record_exception/5,6`

`otel_span:end_span/2` (`deps/opentelemetry_api/src/otel_span.erl:282-306`)
only acts when `is_recording` is true and returns the ctx unchanged
otherwise, so double-ending an already-ended span is a harmless no-op that
returns the same ctx.

**Context manipulation.** `OpenTelemetry.Ctx`
(`deps/opentelemetry_api/lib/open_telemetry/ctx.ex:10-19`) is entirely
delegates to `:otel_ctx`. `new/0` returns `#{}`; `attach/1` does
`erlang:put(?CURRENT_CTX, Ctx)` in the **process dictionary** and returns a
token that is currently the prior context map itself; `detach/1` restores that
token rather than clearing. `set_current_span/2` on the Tracer
(`deps/opentelemetry_api/lib/open_telemetry/tracer.ex:71`) is the *pure* form -
it returns an updated `Ctx` map under the key `{:otel_tracer, :span_ctx}`
without attaching it - which is what makes a span context storable in ETS and
carryable across handler invocations.

**Links** (for ots-j82, noted here because the ETS slot this slice creates
feeds them): `OpenTelemetry.link/1,2`
(`deps/opentelemetry_api/lib/open_telemetry.ex:168,174`) builds a link map
from a `span_ctx`, so the "last span context" the table holds should be the
`span_ctx` record itself.

**Degradation with no SDK.** `:opentelemetry.get_tracer/0`
(`deps/opentelemetry_api/src/opentelemetry.erl:220-226`) falls back to
`{otel_tracer_noop, []}` from `persistent_term`. `otel_tracer_noop:start_span/4`
returns `?NOOP_SPAN_CTX` - `trace_id=0`, `is_valid=false`,
`is_recording=false`. Because `is_recording` is false, every `otel_span` call
guarded by `?is_recording(SpanCtx)` (`deps/opentelemetry_api/src/otel_span.erl:45`)
short-circuits and returns `false`. Nothing raises. This is the mechanism
behind the design note's trace-off degradation: with no SDK started, the whole
bridge is a cheap no-op.

### `:telemetry` handler mechanics and the defensive boundary

`deps/telemetry/` is version 1.4.2 (`mix.lock`).

- `attach/4` is literally `attach_many(HandlerId, [EventName], Function, Config)`
  (`deps/telemetry/src/telemetry.erl:102-103`). Both return
  `ok | {error, already_exists}`.
- The docs for `attach_many/4` (`deps/telemetry/src/telemetry.erl:109-111`)
  carry the warning this bead's constraint restates: "failure of the handler
  on any of these invocations will detach it from **all** the events in
  `EventNames`."
- The failure path is `do_execute/4`
  (`deps/telemetry/src/telemetry.erl:196-215`): a `try` around
  `HandlerFunction(EventName, Measurements, Metadata, Config)`, and on any
  raise/exit/throw it calls `detach(HandlerId)`, executes
  `[telemetry, handler, failure]` with `#{event_name, handler_id,
  handler_config, kind, reason, stacktrace}`, and `?LOG_ERROR`s through
  `report_cb/1` (`:451-454`), whose message is
  `"Handler ~p has failed and has been detached. Class=~p~nReason=~p~nStacktrace=~p~n"`.
- The handler runs in the **emitting** process:
  "All the handlers are executed by the process dispatching event"
  (`deps/telemetry/src/telemetry.erl:190`). Combined with
  `Statifier.Session` being a GenServer, every event for a session is
  serial and in that session's process.
- Performance note the docs make twice (`deps/telemetry/src/telemetry.erl:112-116`):
  use a remote function capture (`&Mod.fun/4`), never a literal `fn` or a
  local capture, or `report_cb/1` logs the local-function warning.
- `merge_ctx/2` (`deps/telemetry/src/telemetry.erl:446-448`) is what
  `:telemetry.span/3` uses to stamp `telemetry_span_context`. Statifier does
  **not** go through it - it puts the reference in `metadata.span_ref`
  directly, by hand, for the reason at
  `deps/statifier/lib/statifier/session/telemetry.ex:57-62`.

The consequence for this slice is concrete: the constraint "a malformed event
is a dropped span, never a crashed session" is not satisfied by `:telemetry`'s
own catch - that catch *removes the bridge*. The handler function itself has
to be the boundary, so that no shape a handler encounters can propagate out of
it.

### Testing against the SDK

`deps/opentelemetry/` is the SDK at 1.7.0, test-only. It ships
`otel_simple_processor.erl` and `otel_exporter_pid.erl` alongside
`otel_batch_processor.erl` (`deps/opentelemetry/src/`), which is the standard
in-process capture pair the contrib bridges use. `config/test.exs` already
sets `traces_exporter: :none` and says tests attach their own exporter.
[`mix.exs:36`](https://github.com/riddler/opentelemetry_statifier/blob/ca90f35e1bb4e938c2922ad1cc2a9b4cd180b10a/mix.exs#L36) puts `test/support` on the test compile path and
`coveralls.json` skips it, so a support module holding that wiring will not
be measured against the 90% coverage floor.

### Prior art in the `opentelemetry_oban` / `opentelemetry_ecto` mold

Surveyed from live `main` of `open-telemetry/opentelemetry-erlang-contrib`.
The family is less uniform than the mold suggests; what follows is what
actually exists, not a recommendation.

**`setup/1` shapes - three styles, no convention.**

| Library | Attach call | handler_id | Double-`setup` |
|---|---|---|---|
| `opentelemetry_oban` | `attach/4`, one per event | `"#{__MODULE__}.job_start"` (string) | result discarded, returns `:ok` |
| `opentelemetry_ecto` | `attach/4` per event | `{__MODULE__, event}` | matched: `{:error, :already_exists} -> :error` |
| `opentelemetry_bandit` | one `attach_many/4` | `{__MODULE__, config.handler_id}`, the id a user-settable option | `attach_many`'s result returned raw, contradicting its own `@spec ... :: :ok` |
| `opentelemetry_phoenix` | `attach/4` for singletons, `attach_many/4` for groups | `{__MODULE__, :endpoint_start}`, `{__MODULE__, :live_view}` | discarded, returns `:ok` |
| `opentelemetry_absinthe` | `attach/4` per event | `{__MODULE__, :operation_start}` | discarded |

Every one of them validates opts with `NimbleOptions` and converts to a map.
This project has no `nimble_options` dependency today, so adopting that costs
a dep ([`mix.exs:38-56`](https://github.com/riddler/opentelemetry_statifier/blob/ca90f35e1bb4e938c2922ad1cc2a9b4cd180b10a/mix.exs#L38-L56)).

`opentelemetry_absinthe` is the **only** library in the family with a real
`teardown/0` (four `:telemetry.detach/1` calls). Oban has one only in
`test/support/test_helpers.ex`, which sweeps `:telemetry.list_handlers([:oban])`.
Ecto's test suite does the same with an explicit exclusion for its `:init`
handler. The pattern that emerges: no teardown in `lib/`, and every test
suite writing its own detach in `on_exit`.

**Where setup options live at event time: the `:telemetry.attach` `Config`
argument, in every case.** It is validated at setup, turned into a map, and
pattern-matched in the handler head (bandit's
`defp set_req_header_attrs(attrs, _conn, %{request_headers: []}), do: attrs`
is the idiom). `:persistent_term` and ETS appear only for state arriving from
a *different* event than the one being handled - `opentelemetry_ecto` stores
repo connection metadata from `[:ecto, :repo, :init]` for use during
`[..., :query]`, with `repo_metadata_storage: :persistent_term | :ets` as a
user option (ETS exists only to avoid `persistent_term.put`'s global GC cost
under many dynamic repos). Application env is read only by absinthe, and only
at setup time, merged under explicit opts.

That is directly relevant here: `record_datamodel_values` is a static setup
option, so the handler `Config` argument is the family's answer, and no ETS
or persistent_term is needed for it.

**Non-lexically-scoped spans - four approaches, and none stores a span in
ETS.**

1. **`opentelemetry_telemetry` / `otel_telemetry.erl`** is the canonical
   utility, used by oban, phoenix LiveView, cowboy, broadway, grpc and
   others. `start_telemetry_span/4` captures
   `ParentCtx = otel_tracer:current_span_ctx()`, starts the span, makes it
   current, and stores the **pair** `{ParentCtx, Ctx}` in the **process
   dictionary**; `end_telemetry_span/2` pops it, ends the span, and restores
   `ParentCtx` as current. It keys on `metadata.telemetry_span_context` when
   present, and otherwise on a per-`tracer_id` **stack** - explicitly to cope
   with nesting. It never uses `Ctx.attach`/`Ctx.detach` for this; only
   `otel_tracer:set_current_span/1`.

   Its moduledoc names the constraint in so many words: "Span contexts are
   currently stored in the process dictionary, so spans can only be
   correlated within a single process at this time."

2. **`opentelemetry_bandit`** stores nothing at all - `Tracer.start_span |>
   Tracer.set_current_span` in the start handler, `Tracer.end_span()` then
   `Ctx.clear()` in the stop handler. It works only because a whole request
   is one process and no other span is open there.

3. **`opentelemetry_absinthe`** hand-rolls approach 1 with
   `Process.put({__MODULE__, :parent_ctx}, ...)` - no stack, so it cannot
   nest.

4. **`opentelemetry_ecto`** is the one place `Ctx.attach`/`Ctx.detach` tokens
   are actually paired, and it is not cross-event: the span is started and
   ended inside a single stop-only handler, so the token lives on the stack.

Two of these bear directly on decisions this slice makes. First,
`otel_telemetry`'s keying is the same problem `span_ref` solves, and it
reaches for a stack precisely where statifier's contract hands the bridge an
exact reference - so a `span_ref`-keyed table is strictly better-informed
than the family's fallback. Second, nothing in the family keeps open spans in
ETS; the design note's ETS table is a departure from prior art, justified by
the last-span-context-per-session slot that ots-j82 needs, which the process
dictionary cannot supply once the process is shared across sessions.

**Explicit `start_time` from a measurement: three libraries do it, all
back-calculated from a stop event.** `opentelemetry_ecto`,
`opentelemetry_finch` and `opentelemetry_redix` all compute
`end_time = :opentelemetry.timestamp(); start_time = end_time - duration` and
pass it into `start_span`'s opts. No conversion, because both sides are
native monotonic. **No library passes a `start_time` taken from a `:start`
event's `monotonic_time`** - which is what this bead does, and it is
strictly more accurate than the back-calculation, since the measurement is
the real reading.

One trap worth naming: `OpentelemetryTelemetry`'s own moduledoc example shows
`def handle_event(_event, %{system_time: start_time}, ...)` feeding
`%{start_time: start_time}`. That is wrong - the SDK wants native
**monotonic**, and `system_time` is not it. No library in the repo actually
does this; statifier's `:start` half carries both `system_time` and
`monotonic_time`, and `monotonic_time` is the one to use.

**Defensive handler boundaries: nobody uses try/rescue.** An exhaustive
search of `instrumentation/**/lib/*.ex` finds exactly one `rescue`, and it
is in `OpentelemetryOban.insert!/3` wrapping the *user's* `Oban.insert!`
call to record an exception and reraise - not a handler boundary. The
family's actual defensive posture is **catch-all pattern-match clauses**:
`otel_telemetry.erl`'s final `handle_event(_Event, _Measurements, _Metadata,
_Config) -> ok.`, ecto's `defp query_opts(_), do: %{}`, oban's
`defp set_error_type(_error), do: :ok`, bandit's no-conn fallback clause,
`pop_ctx` returning `undefined` and `end_telemetry_span` no-opping on an
empty stack, and finch validating with a `Logger.warning` fallback instead of
raising.

So the project's stated constraint ("a malformed event is a dropped span,
never a crashed session") has prior art in *shape* - total functions with
catch-alls - rather than in a rescue at the boundary. Worth noting because
the same convention list in `CLAUDE.md` forbids rescue-to-default at a leaf;
total clauses satisfy both.

Also from `:telemetry` itself, three details for the design notes: the catch
covers `error | exit | throw`; a `[:telemetry, :handler, :failure]` event is
emitted before the log, so the bridge could attach to *that* to observe
itself being detached; and `attach_many/4`'s all-events detach is the direct
argument for splitting handler ids if partial survival matters.

**Testing: two flavors, one record idiom.** Every Elixir test in the family
extracts records in bulk rather than singly:

```elixir
require Record

for {name, spec} <- Record.extract_all(from_lib: "opentelemetry/include/otel_span.hrl") do
  Record.defrecord(name, spec)
end
```

Flavor A (bandit, finch, phoenix, redix, absinthe) puts
`config :opentelemetry, processors: [{:otel_simple_processor, %{}}]` in
`config/test.exs` and calls `:otel_simple_processor.set_exporter(:otel_exporter_pid, self())`
in `setup`, with `on_exit(fn -> :telemetry.detach(...) end)`. Flavor B (oban,
ecto) stops and restarts the `:opentelemetry` application per test group with
`{:otel_batch_processor, %{scheduled_delay_ms: 1, exporter: {:otel_exporter_pid, self()}}}`.
Assertions are `assert_receive {:span, span(name: "...", kind: ..., links: links)}`,
with `:otel_attributes.map/1` to unpack attributes and `:otel_links.list/1`
for links.

Flavor A is the closer fit here: `config/test.exs` already carries the
"tests attach their own in-process exporter" decision, and this bridge has no
application to restart.

Every library keeps `opentelemetry` and `opentelemetry_exporter` as
`only: [:test]` deps with `opentelemetry_api` at runtime - which is exactly
[`mix.exs:38-56`](https://github.com/riddler/opentelemetry_statifier/blob/ca90f35e1bb4e938c2922ad1cc2a9b4cd180b10a/mix.exs#L38-L56) and ADR-0002 decision 5 already.

**ETS in the family.** Only two `:ets.new` calls exist in the whole contrib
repo's `lib/`. Ecto's `:otel_ecto_repo_meta` is `:public, :named_table`,
lazily created by whichever process runs the `:init` handler, with no heir,
no supervisor and no delete path - if that process dies the table vanishes
and reads crash. `OpentelemetryRedix.ConnectionTracker` is the one properly
owned table and the closest structural prior art for this slice: a GenServer
owns it, the table name rides in the telemetry handler `Config` so tests can
inject it, `Process.flag(:trap_exit, true)` plus `terminate/2` detaches the
handlers on shutdown, and cleanup is event-driven (the `:disconnection` event
deletes the row). Its known gap is exactly the one ots-lt6 exists to close:
no monitor and no TTL sweep, so an entity that dies without emitting its
closing event leaks a row.

## Code References

- [`lib/opentelemetry_statifier.ex:1-30`](https://github.com/riddler/opentelemetry_statifier/blob/ca90f35e1bb4e938c2922ad1cc2a9b4cd180b10a/lib/opentelemetry_statifier.ex#L1-L30) - the placeholder module and `setup/0`
- [`test/opentelemetry_statifier_test.exs:1-10`](https://github.com/riddler/opentelemetry_statifier/blob/ca90f35e1bb4e938c2922ad1cc2a9b4cd180b10a/test/opentelemetry_statifier_test.exs#L1-L10) - the one existing test
- [`test/test_helper.exs:1`](https://github.com/riddler/opentelemetry_statifier/blob/ca90f35e1bb4e938c2922ad1cc2a9b4cd180b10a/test/test_helper.exs#L1) - bare `ExUnit.start()`
- [`config/test.exs:1-6`](https://github.com/riddler/opentelemetry_statifier/blob/ca90f35e1bb4e938c2922ad1cc2a9b4cd180b10a/config/test.exs#L1-L6) - `traces_exporter: :none`, in-process exporter policy
- [`mix.exs:36`](https://github.com/riddler/opentelemetry_statifier/blob/ca90f35e1bb4e938c2922ad1cc2a9b4cd180b10a/mix.exs#L36) - `elixirc_paths(:test)` includes `test/support`
- [`mix.exs:38-56`](https://github.com/riddler/opentelemetry_statifier/blob/ca90f35e1bb4e938c2922ad1cc2a9b4cd180b10a/mix.exs#L38-L56) - dep list; API at runtime, SDK test-only
- [`mix.exs:59-72`](https://github.com/riddler/opentelemetry_statifier/blob/ca90f35e1bb4e938c2922ad1cc2a9b4cd180b10a/mix.exs#L59-L72) - `statifier_dep/0`, `STATIFIER_PATH` override
- [`coveralls.json:1-8`](https://github.com/riddler/opentelemetry_statifier/blob/ca90f35e1bb4e938c2922ad1cc2a9b4cd180b10a/coveralls.json#L1-L8) - 90% floor, `test/support/` skipped
- `.quality.exs:22-33` - `warnings_as_errors`, credo strict, loop profile
- [`docs/adr/0002-adopts-the-upstream-bridge-contract.md:28-63`](https://github.com/riddler/opentelemetry_statifier/blob/ca90f35e1bb4e938c2922ad1cc2a9b4cd180b10a/docs/adr/0002-adopts-the-upstream-bridge-contract.md#L28-L63) - the five
  binding decisions, including API-only in `lib/`
- `deps/statifier/lib/statifier/session/telemetry.ex:33-62` - span correlation:
  why `span_ref`, why not `(session_id, macrostep)`
- `deps/statifier/lib/statifier/session/telemetry.ex:64-78` - the two consumer
  caveats: unmatched starts, and the `:initialize` skew
- `deps/statifier/lib/statifier/session/telemetry.ex:112-135` - the lifecycle
  event table and the `:native` duration note
- `deps/statifier/lib/statifier/session/telemetry.ex:225-273` - the three kind
  lists and `events/0`
- `deps/statifier/lib/statifier/session/telemetry.ex:356-373` - `macrostep_start/4`
- `deps/statifier/lib/statifier/session/telemetry.ex:386-414` - `macrostep_stop/7`
- `deps/statifier/lib/statifier/session/telemetry.ex:720-722` - `event_name/1`,
  `nil` for a `nil` event
- `deps/statifier/lib/statifier/session.ex:839-853` - the `:initialize` span's
  start, emitted after `boot/6`
- `deps/statifier/lib/statifier/session.ex:1196-1209` - its stop, one
  `handle_continue` later
- `deps/statifier/lib/statifier/session.ex:1508-1540` - `in_macrostep/4`, the
  nesting the local bindings protect
- `deps/opentelemetry_api/src/otel_span.erl:47-52` - the real `start_opts` type
- `deps/opentelemetry_api/src/otel_span.erl:62-75` - `validate_start_opts/1`
- `deps/opentelemetry_api/src/otel_span.erl:282-306` - `end_span/1,2`, the
  `is_recording` guard
- `deps/opentelemetry_api/src/opentelemetry.erl:328-330` - `timestamp/0` is
  `erlang:monotonic_time()`
- `deps/opentelemetry_api/lib/open_telemetry/tracer.ex:28-104` - the four macros
- `deps/opentelemetry_api/lib/open_telemetry/span.ex:87-193` - the ctx-explicit
  functions
- `deps/opentelemetry_api/lib/open_telemetry/ctx.ex:10-19` - the Ctx delegates
- `deps/telemetry/src/telemetry.erl:102-116` - `attach/4`, `attach_many/4`, the
  all-events detach warning and the capture-performance note
- `deps/telemetry/src/telemetry.erl:196-215` - `do_execute/4`, the catch and
  detach
- `deps/telemetry/src/telemetry.erl:451-454` - the detach log message
- `/Users/johnnyt/repos/github/statifier-ex/docs/opentelemetry.md:64-203` -
  span topology, attributes, cardinality, failure tolerance, trace-off
- `/Users/johnnyt/repos/github/statifier-ex/docs/adr/0062-opentelemetry-bridge-is-a-separate-package.md` -
  packaging and scope

## Architecture Documentation

**The mapping is decided upstream; the mechanism is decided here.** ADR-0002
decision 3 makes statifier-ex's `docs/opentelemetry.md` the reference for span
topology, links, the `statifier.*` namespace, the datamodel opt-in, and
trace-off degradation, and its Consequences section says the complement
explicitly: "Handler modules, ETS span-table ownership, sweeper design, and
the setup API are this repository's decisions." So the *shape* of the span is
not this bead's to choose; how `setup/1` attaches, how the table is owned, and
what the handler module looks like are.

**Public events only, structurally.** ADR-0002 decision 1 and st-ADR-0062
decision 4. Nothing in the bead's scope needs an internal reach - `span_ref`,
`trigger`, `event_name`, `outcome`, the counters and `monotonic_time` are all
metadata or measurements on the two public events. The design note names the
one thing that *is* missing (caller trace context, st-yoi0 upstream) and
records it as future upstream work rather than a bridge workaround.

**Nothing unbounded by default.** The design note's cardinality section makes
`record_datamodel_values: false` the default. The events it gates belong to
ots-j82, but `setup/1` is where the option is read, so this slice defines
where setup options live and how a handler reads them at event time.

**Defensive at the boundary.** `CLAUDE.md`'s Conventions section states the
nuance: "a telemetry handler that raises is detached by `:telemetry` itself -
handlers must be defensive at the boundary, and a malformed event is a dropped
span, never a crashed session." The upstream mechanism is
`deps/telemetry/src/telemetry.erl:196-215`, and under `attach_many/4` the
detach is total across the name list. Note this sits alongside the project's
other inherited convention - "errors are events, never rescue-to-default at a
leaf" - so the defensiveness is explicitly a *boundary* property, not a
per-function one.

**Project conventions this slice must satisfy** (`CLAUDE.md`): structs and
MapSets; `@spec` on public functions; pattern matching over multiple asserts;
a state/session argument goes first; every new test asserting `lib/` behavior
gets a sabotage line (`# sabotage: <what was broken> -> red`); full
`mix quality` green before any commit, and the gate formats. Writing style for
new files here is plain ASCII punctuation, but note that both this repo's
existing prose and the upstream documents use hyphen-dash style already, so
matching the neighbors and the personal default coincide.

**Authority.** `CLAUDE.md`'s "Agent authority in this repo" states this
repository has *not* opted into statifier-ex's team-maintainer profile - bd
tracking and test runs are agent work; commits, pushes, and bead closes are
human calls.

## Historical Context

- `docs/adr/0001-record-architecture-decisions.md` establishes the ADR
  practice and the cross-repo citation convention (`st-ADR-NNNN` for
  statifier-ex, bare `ADR-NNNN` for this repo). Its Consequences already
  anticipate this bead's boundary: "Event-contract questions go to
  statifier-ex; span-mapping questions are decided here."
- st-ADR-0040's amendment history (st-f6i9, st-ii9v, st-oef3, st-1xwh) shows
  the contract growing from 25 names to 27 (`:datamodel_change` and
  `:datamodel_init`) and the trace family's `location` key being withdrawn.
  The st-ii9v amendment's fourth argument names *this* bridge as the reason
  withdrawal was the reversible direction: "removing one after the
  OpenTelemetry bridge ships against these shapes is breaking."
- st-ADR-0040's "One new clock read" section is why `duration` exists at all
  and why it is `:native`; it also records `%State{}.macrostep_started_at`,
  which is the field `in_macrostep/4` manages.
- `deps/statifier/docs/observability.md:198-230` (constraint 6) is where the
  telemetry bridge is anchored in statifier's own architecture. It contains
  no OTel mapping - it points at `Statifier.Session.Telemetry` and ADR-0040
  and stops there. The OTel mapping was never in this file.

## Related Research

No prior research documents exist in this repository - `docs/research/` is
created by this document. Upstream, `deps/statifier/docs/plans/260816-st-cmq.1-session-telemetry-effect-trace-streams.md`
is the plan that built the telemetry contract this bridge consumes, and
`deps/statifier/docs/research/260816-st-cmq.9-corpus-flip-send-invoke-ratchet.md`
mentions it in passing.

External sources for the prior-art section, all read from live `main`:

- https://github.com/open-telemetry/opentelemetry-erlang-contrib/blob/main/instrumentation/opentelemetry_oban/lib/opentelemetry_oban.ex
- https://github.com/open-telemetry/opentelemetry-erlang-contrib/blob/main/instrumentation/opentelemetry_oban/lib/opentelemetry_oban/job_handler.ex
- https://github.com/open-telemetry/opentelemetry-erlang-contrib/blob/main/instrumentation/opentelemetry_ecto/lib/opentelemetry_ecto.ex
- https://github.com/open-telemetry/opentelemetry-erlang-contrib/blob/main/instrumentation/opentelemetry_bandit/lib/opentelemetry_bandit.ex
- https://github.com/open-telemetry/opentelemetry-erlang-contrib/blob/main/instrumentation/opentelemetry_phoenix/lib/opentelemetry_phoenix.ex
- https://github.com/open-telemetry/opentelemetry-erlang-contrib/blob/main/instrumentation/opentelemetry_absinthe/lib/instrumentation.ex
- https://github.com/open-telemetry/opentelemetry-erlang-contrib/blob/main/instrumentation/opentelemetry_redix/lib/opentelemetry_redix/connection_tracker.ex
- https://github.com/open-telemetry/opentelemetry-erlang-contrib/blob/main/utilities/opentelemetry_telemetry/src/otel_telemetry.erl
- https://github.com/open-telemetry/opentelemetry-erlang-contrib/blob/main/utilities/opentelemetry_telemetry/lib/opentelemetry_telemetry.ex
- https://github.com/beam-telemetry/telemetry/blob/main/src/telemetry.erl
- https://github.com/open-telemetry/opentelemetry-erlang/blob/main/apps/opentelemetry_api/src/opentelemetry.erl

## Open Questions

Recorded rather than asked - no human was available during this pass.

1. **The pinned dependency does not contain the binding design documents.**
   `mix.lock` pins statifier at `fe77a8249f58e463c69634987ab2000101a152cf`.
   That tree has `docs/adr/` up to 0061 and no `docs/opentelemetry.md`. Both
   st-ADR-0062 and the design note exist on the sibling checkout's `main`
   (`/Users/johnnyt/repos/github/statifier-ex`, currently `063e3aa`), and
   this research read them there. This is not a blocker for implementing the
   slice - the event shapes the bridge consumes *are* in the pinned tree -
   but it means the pin should probably move before or with this work, and
   until it does, anyone reading `deps/statifier/docs/` for the design note
   will not find it. Whether to advance the pin is a human call under
   st-ADR-0061.

   **Tracked (2026-08-21):** filed as `ots-nxl`. Still open - the call is a
   human one under st-ADR-0061 and is not taken here.

2. **`trigger` has five values, not four.** The design note (upstream
   `docs/opentelemetry.md:73-74`) enumerates
   `initialize | event | cancel | internal`, and so does st-ADR-0040's
   ADR-0029-interaction section. The pinned code's specs
   (`deps/statifier/lib/statifier/session/telemetry.ex:358`, `:388`) and
   `boot/6` (`deps/statifier/lib/statifier/session.ex:1039-1062`) also emit
   `:resume`, added by st-ADR-0060's resume-from-persisted-position work.
   The `statifier.trigger` attribute is a pass-through string either way, so
   nothing breaks - but any test or doc here that enumerates the domain
   should use five, and the upstream note's list is stale. Under the CLAUDE.md
   cross-repo table this is statifier-ex's to correct.

   **Tracked (2026-08-21):** filed as `ots-2bs` (label `upstream`; the work
   lands in statifier-ex). Still open here.

3. **Where setup options live at event time - prior art answers this, but the
   validation library is still a choice.** The design note names
   `record_datamodel_values: true` as a setup option but not the mechanism.
   The contrib family is unanimous: the `Config` argument of
   `:telemetry.attach/4` / `attach_many/4`, validated at setup and
   pattern-matched in the handler head. `persistent_term` and ETS appear only
   for state arriving from a *different* event, which this option is not.
   What is genuinely open: every one of those libraries reaches for
   `NimbleOptions` to validate and normalize, and this project has no such
   dependency. Whether to add one for a two-key option map is a call for the
   plan.

   **Settled (2026-08-21):** Options travel in the `:telemetry.attach/4` `Config`
   argument as the family does it, but validated by a hand-rolled
   `Config.new/1` returning `{:ok, t} | {:error, reason}` - no `nimble_options`
   dependency for a two-key option map. Unknown keys are rejected rather than
   ignored, since a typo'd `record_datamodel_value` silently doing nothing is
   precisely the failure the cardinality policy cannot absorb. ADR-0003
   decision 1.

4. **`setup/1` called twice returns `{:error, :already_exists}`, and the
   family genuinely disagrees on what to do about it.** Oban discards the
   result and returns `:ok`; ecto matches it and returns a bare `:error`
   (contradicting its own `@spec`); bandit returns `attach_many`'s result raw
   (also contradicting its `@spec ... :: :ok`). Two of the three are
   upstream bugs, which is a reason to decide deliberately rather than copy.
   Related: only `opentelemetry_absinthe` ships a `teardown/0` in `lib/` -
   everyone else's test suite writes its own detach in `on_exit`, so if this
   package wants a testable teardown it should probably have a real one. The
   bead does not mention `detach/0` and no upstream record requires it.

   **Settled (2026-08-21):** `setup/1` is idempotent and returns `:ok` - it calls
   `teardown/0` before re-attaching rather than surfacing
   `{:error, :already_exists}`, so neither ecto's nor bandit's `@spec`
   contradiction is reproduced. A real `teardown/0` ships in `lib/` rather than
   being rewritten in each test's `on_exit`, following `opentelemetry_absinthe`.
   Verified at runtime during /wurk:verify: a second `setup/0` leaves 27 handlers,
   not 54. ADR-0003 decisions 3 and 7.

5. **Whether one handler id or several is right.** `attach_many/4`'s
   all-or-nothing detach is the argument for splitting (a malformed
   `:datamodel_init` should not take the macrostep spans down with it); one
   id is the argument for a single teardown handle. Bandit uses one
   `attach_many/4` for three events; phoenix mixes both in one `setup`; oban
   and ecto use one id per event. Defensive total clauses make the split less
   necessary either way. Plan-time decision.

   **Settled (2026-08-21):** Several - one `:telemetry.attach/4` id per event
   name, 27 in total. `attach_many/4`'s detach is all-or-nothing across the name
   list, so a raise in one clause would otherwise cost the whole bridge for the
   life of the VM. `teardown/0` gives back the single detach handle that argued
   for one id. Verified at runtime during /wurk:verify: 27 handlers, 27 unique
   ids. ADR-0003 decision 2.

6. **The ETS table's owner process is unspecified by this slice.** The design
   note says the bridge "owns" the table; ots-lt6 owns the cleanup and sweep.
   A named public table created in `setup/1` has no owning process to die
   with it - which is exactly `opentelemetry_ecto`'s latent bug, where the
   table vanishes with whichever process first ran the `:init` handler.
   `OpentelemetryRedix.ConnectionTracker` is the counter-example: a GenServer
   owner, the table name passed through the handler `Config` so tests can
   inject it, and `trap_exit` + `terminate/2` detaching the handlers. Adding
   a GenServer is a supervision-tree question this bead does not name, and
   deciding it here constrains ots-lt6, so it is worth deciding deliberately.

   **Settled (2026-08-21):** A supervised `SpanTable` GenServer owns it, started
   from a new `mod:` in `mix.exs`, with the table name passed through the handler
   `Config` so tests inject their own - `OpentelemetryRedix.ConnectionTracker`'s
   shape, not `opentelemetry_ecto`'s ownerless one. Verified at runtime during
   /wurk:verify: the table exists at boot with no `setup/1` call, and killing the
   owner has the supervisor restart it with the table recreated empty. ADR-0003
   decision 4.

7. **Whether `statifier.session_id` alone keys the table.** The design note
   says "the last-emitted span context per `session_id`", but the open span
   is per `span_ref` and re-entry means a session can have two open at once.
   The table probably needs two logical slots with different keys, which is a
   shape decision this slice makes and ots-j82 reads.

   **Settled (2026-08-21):** It does not. The table carries two tagged slots
   with different keys - `{:span, span_ref}` for the open span and
   `{:last_span_ctx, session_id}` for the last-emitted context - with
   `session_id` denormalized onto the span row so ots-lt6 can sweep by session.
   Verified at runtime during /wurk:verify: after a start/stop pair the open-span
   row is gone and only the `{:last_span_ctx, _}` row remains. ADR-0003
   decision 6.

8. **Whether to depend on `opentelemetry_telemetry` at all.** It is the
   utility oban, phoenix LiveView, cowboy and broadway all use for exactly
   this start-handler/stop-handler problem, so not using it needs a reason.
   The reason appears to be real: it stores span contexts in the **process
   dictionary**, keyed on `metadata.telemetry_span_context` or a per-tracer
   stack. Statifier does not set `telemetry_span_context` - it puts its
   reference in `metadata.span_ref` by hand - so the utility would fall back
   to its stack, which its own moduledoc calls a way "to lessen the
   likelihood of inadvertently closing the wrong span" rather than a
   guarantee. Given an exact `span_ref` and a required ETS table for the
   last-span-context slot anyway, rolling the pairing here looks right, but
   the record should say so rather than leaving the omission unexplained.
   It would also add a runtime dependency ADR-0002 decision 5 does not
   currently contemplate.

   **Settled (2026-08-21):** No. `opentelemetry_telemetry` keys on the process
   dictionary via `metadata.telemetry_span_context` or a per-tracer stack, and
   statifier sets neither - it puts its own reference in `metadata.span_ref`.
   The utility would fall back to the stack heuristic its own moduledoc calls a
   way "to lessen the likelihood" of closing the wrong span, where `span_ref` is
   exact. It would also add a runtime dependency ADR-0002 decision 5 does not
   contemplate. Rolled by hand; the omission is now explained in ADR-0003
   decision 5 rather than left silent.

9. **The `record_exception` asymmetry, for ots-lt6's error status.**
   `OpenTelemetry.Span.record_exception/2,3,4` is an Elixir-level
   reimplementation over `add_event`, not a delegate to Erlang's
   `otel_span:record_exception/5,6`, and it expects an `Exception.t()`. An
   orphaned span has no exception to record - it needs
   `Span.set_status(ctx, OpenTelemetry.status(:error, msg))` instead. Noted
   here because this slice decides what the table stores, and a span_ctx is
   what that call needs.

   **Settled (2026-08-21):** Answered structurally rather than chosen. The
   table stores the `span_ctx` itself (`SpanEntry.span_ctx`), which is exactly
   the argument `Span.set_status/2` takes, so ots-lt6 can end an orphan with an
   error status without ever needing an `Exception.t()`. No `record_exception`
   call is made in this slice. Recorded in ADR-0003 decision 6.

## Out of scope for this bead

Noted so a plan does not drift into them:

- **ots-j82** - the 11 core-effect and 9 trace events becoming span events;
  `location` flattening to `statifier.source.line`/`.column`; `configuration`
  as a string array on those events; the previous-macrostep and invoke-parent
  links; the `record_datamodel_values` *gate itself* (this slice only parses
  the option).
- **ots-lt6** - `:terminate` cleanup of the ETS entry, the orphan sweep that
  ends unmatched open spans with an error status, and the `trace: false`
  degradation test.
- **ots-6ns** - CI running the full gate on main.
- **Caller context propagation** - the design note's session-process caveat.
  Not implementable from the public events as they stand; the upstream slot
  is st-yoi0 in statifier-ex.
- **Sibling packages** (`statifier_persistence`, `statifier_oban`,
  `statifier_ui`, `predicator`) - family scope is real but each has its own
  design bead upstream.
