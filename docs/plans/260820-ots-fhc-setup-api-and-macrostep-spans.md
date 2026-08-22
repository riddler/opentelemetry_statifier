---
date: 2026-08-20
planner: Claude
git_commit: ca90f35e1bb4e938c2922ad1cc2a9b4cd180b10a
branch: ots-fhc-setup-macrostep-spans
repository: opentelemetry_statifier
beads_issue: ots-fhc
topic: "ots-fhc: setup/1 handler attach and macrostep spans paired on span_ref"
status: ready
last_updated: 2026-08-20
last_updated_by: Claude
---

# Setup API and Macrostep Spans Implementation Plan

## Overview

The first executable slice of the bridge. `OpentelemetryStatifier.setup/1`
attaches a handler to every one of the 27 names
`Statifier.Session.Telemetry.events/0` returns; the macrostep `:start` event
opens a root span named `statifier.macrostep`, and the `:stop` event whose
`span_ref` matches closes it. Span timing comes from the events' own
`monotonic_time` measurements. An ETS table owned by a supervised process
holds the open spans and, per session, the last span context that ots-j82's
links will read.

Beads issue: `ots-fhc` (child of epic `ots-8wp`, mirrors `st-cmq.2`). Siblings
`ots-j82`, `ots-lt6` and `ots-6ns` all depend on this one.

## Current State Analysis

This repository is a scaffold. Everything load-bearing is upstream, and the
research pass (`docs/research/260820-ots-fhc-setup-api-and-macrostep-spans.md`)
read it there.

- `lib/opentelemetry_statifier.ex:1-30` is the whole of `lib/`: a moduledoc
  and a placeholder `setup/0` returning `:ok` with a doctest. No `setup/1`,
  no handler module, no ETS table, no attribute helper.
- `test/opentelemetry_statifier_test.exs:1-10` is the whole suite, carrying
  the project's required sabotage line. `test/test_helper.exs:1` is a bare
  `ExUnit.start()` - no SDK wiring. `test/support/` does not exist yet, even
  though `mix.exs:36` already puts it on the test compile path and
  `coveralls.json` already skips it.
- `config/test.exs:1-6` sets `traces_exporter: :none` and records the
  decision that "tests that assert on spans attach their own in-process
  exporter". No processor is configured, so nothing is capturable today.
- `mix.exs:38-56` has `opentelemetry_api ~> 1.4` and `telemetry ~> 1.0` at
  runtime and `opentelemetry ~> 1.5` test-only; `mix.lock` resolves 1.5.0,
  1.4.2 and 1.7.0. `mix.exs:29-33` has `application/0` with
  `extra_applications: [:logger]` and **no `mod:`** - the package starts no
  process today.
- `.quality.exs` gates `warnings_as_errors`, credo `--strict`, dialyzer and
  a 90% coverage floor (`coveralls.json`). There is no Doctor stage, so
  `@moduledoc`/`@doc`/`@spec` coverage is a convention here, not a check.

The constraints are recorded rather than discovered:

- `docs/adr/0002-adopts-the-upstream-bridge-contract.md` decisions 1, 3 and 5:
  public events only; statifier-ex `docs/opentelemetry.md` governs the
  mapping; `lib/` depends on `opentelemetry_api` alone. Its Consequences
  section is the licence for this plan's mechanism choices: "Handler
  modules, ETS span-table ownership, sweeper design, and the setup API are
  this repository's decisions."
- The event shapes are frozen in the pinned dep,
  `deps/statifier/lib/statifier/session/telemetry.ex:112-135` (the table),
  `:225-273` (the three kind lists and `events/0`), `:356-373`
  (`macrostep_start/4`) and `:386-414` (`macrostep_stop/7`).

## Desired End State

After this plan:

1. `OpentelemetryStatifier.setup/1` accepts an options keyword list,
   validates it into a `%OpentelemetryStatifier.Config{}` struct, and
   attaches `&OpentelemetryStatifier.Handler.handle_event/4` to each of the
   27 names under a **per-event handler id**, returning `:ok` (or
   `{:error, reason}` on bad options). `setup/0` delegates to `setup([])`.
   `teardown/0` detaches every id the package owns and returns `:ok`.
2. A supervised `OpentelemetryStatifier.SpanTable` process owns a public
   named ETS table, created when the OTP application starts, holding
   `{{:span, span_ref}, session_id, %SpanEntry{}}` rows for open spans and
   `{{:last_span_ctx, session_id}, session_id, span_ctx}` rows for the link
   slot ots-j82 needs.
3. `[:statifier, :session, :macrostep, :start]` starts a **root** span named
   `statifier.macrostep` with `start_time:` taken from the event's
   `monotonic_time`, stores it under its `span_ref`, and sets the
   `statifier.session_id` / `statifier.trigger` / `statifier.event_name`
   attributes.
4. `[:statifier, :session, :macrostep, :stop]` looks the span up by
   `span_ref`, sets `statifier.outcome`, the counter attributes and
   `statifier.configuration`, ends it at the stop event's `monotonic_time`,
   deletes the open-span row, and writes the ended span context into the
   session's `:last_span_ctx` slot.
5. The other 25 events reach the handler and are silently ignored (ots-j82
   fills them in). A malformed or unrecognised event falls through the
   handler's final catch-all clause and drops the span rather than raising.
6. `docs/adr/0003-*.md` records the mechanism decisions this plan makes, per
   ADR-0002's Consequences.

**How to verify**: `mix quality` green, and the Phase 3 test file asserting
- against an in-process SDK exporter - that a start/stop pair produces one
`statifier.macrostep` span with the expected attributes, that nested
re-entry (`start, start, stop, stop`) produces two spans correctly paired by
`span_ref`, and that an unmatched start produces none.

### Key Discoveries:

- **`span_ref` is a plain metadata key, not `telemetry_span_context`.**
  Statifier hand-rolls its span pair (`deps/statifier/lib/statifier/session/telemetry.ex:33-62`)
  because `:telemetry.span/3` would force an `:exception` half this contract
  does not have. The bridge reads `metadata.span_ref`, and must expect
  starts that never get a stop (`:64-70`).
- **The units line up exactly.** `monotonic_time` is `System.monotonic_time/0`;
  `opentelemetry:timestamp()` is `erlang:monotonic_time()` in native units
  (`deps/opentelemetry_api/src/opentelemetry.erl:328-330`). The measurement
  passes straight into `start_time:` and into `Span.end_span/2` with no
  conversion. `system_time` is **not** interchangeable - that trap is live
  in `OpentelemetryTelemetry`'s own moduledoc example.
- **Each macrostep span is the root of its own trace** - the design note is
  explicit (`/Users/johnnyt/repos/github/statifier-ex/docs/opentelemetry.md:97-117`),
  and rejects both a session-lifetime span and a session-wide trace as
  unbounded. So the bridge must start from a *fresh* context, never from the
  session process's ambient one.
- **`Tracer.start_span/3` is a macro taking an explicit `Ctx`**
  (`deps/opentelemetry_api/lib/open_telemetry/tracer.ex:45`), resolving the
  application tracer from `__CALLER__`, so the handler module needs
  `require OpenTelemetry.Tracer`. `:otel_tracer.start_span/4` returns the
  `span_ctx` (`deps/opentelemetry_api/src/otel_tracer.erl:59-64`), and
  `start_opts` has no `:parent` key - parenting comes from the `Ctx`
  (`deps/opentelemetry_api/src/otel_span.erl:47-52`). Everything else the
  bridge needs is a plain ctx-explicit function on `OpenTelemetry.Span`
  (`deps/opentelemetry_api/lib/open_telemetry/span.ex:87-193`).
- **A raising handler is detached from every event it attached to.**
  `deps/telemetry/src/telemetry.erl:196-215` catches `error | exit | throw`,
  calls `detach(HandlerId)`, and under `attach_many/4` that removes the
  handler from *all* the names (`:109-116`). The project convention forbids
  rescue-to-default at a leaf, and the family's actual defensive posture is
  **total functions with catch-all clauses** - `otel_telemetry.erl`'s final
  `handle_event(_, _, _, _) -> ok.`, ecto's `defp query_opts(_), do: %{}`.
  Both constraints are satisfied by clause exhaustiveness.
- **With no SDK started the whole bridge is a cheap no-op.**
  `:opentelemetry.get_tracer/0` falls back to `otel_tracer_noop`, whose span
  ctx has `is_recording: false`, and every `otel_span` call guarded by
  `?is_recording` short-circuits (`deps/opentelemetry_api/src/otel_span.erl:45,282-306`).
  Double-ending an already-ended span is likewise a harmless no-op.
- **Nothing in the contrib family keeps open spans in ETS**, and the only
  properly owned table in the family is `OpentelemetryRedix.ConnectionTracker`
  (GenServer owner, table name passed through the handler `Config`).
  `opentelemetry_ecto`'s `:otel_ecto_repo_meta` is the counter-example: a
  named public table with no owner, which vanishes if whichever process ran
  the `:init` handler dies.
- **Setup options belong in the `:telemetry` handler `Config` argument** -
  unanimous across the family, validated at setup and pattern-matched in the
  handler head. `persistent_term`/ETS appear only for state arriving from a
  *different* event, which `record_datamodel_values` is not.

## What We're NOT Doing

- **ots-j82's mapping**: the 11 effect and 9 trace events becoming span
  events, `location` flattening to `statifier.source.line`/`.column`, the
  previous-macrostep and invoke-parent links, and the
  `record_datamodel_values` *gate itself*. This slice parses and carries the
  option; it does not yet read it anywhere. The `:last_span_ctx` slot is
  written here and read there.
- **ots-lt6's lifecycle**: `:terminate` cleanup of table rows, the orphan
  sweep that ends unmatched open spans with an error status, and the
  `trace: false` degradation test. Open-span rows therefore accumulate under
  this plan alone; that is expected, is the reason ots-lt6 depends on this
  bead, and is called out in the ADR this plan writes.
- **ots-6ns**: CI.
- **Span status mapping.** No `set_status/2` call in this slice, including
  for `outcome: :budget_exhausted`. The design note maps outcome to an
  *attribute* and assigns error status only to the sweeper's orphans
  (upstream `docs/opentelemetry.md:177-191`). Inventing an outcome-to-status
  rule here would be a mapping decision that belongs upstream under ADR-0002
  decision 3.
- **Exporting the timestamp measurements as attributes.** `system_time` and
  `monotonic_time` are consumed as span timing; re-exporting the same
  reading as `statifier.monotonic_time` is noise on every span. The
  countable measurements (`duration`, `macrostep`, `microsteps`, `rounds`)
  do become attributes, per the design note's uniform rule.
- **Advancing the statifier pin.** See Open Questions Carried Forward.
- **Caller context propagation.** Not implementable from the public events;
  the upstream slot is `st-yoi0`.
- **Sibling packages** (`statifier_persistence`, `statifier_oban`,
  `statifier_ui`, `predicator`).

## Implementation Approach

Four phases, each independently committable and each leaving `mix quality`
green on its own.

The order is bottom-up but each phase is a complete vertical of its own:
Phase 1 makes `setup/1` real and attaches a handler that does nothing but
survive; Phase 2 stands up the table the spans need, with its own tests;
Phase 3 turns the two macrostep events into spans, which is where the SDK
capture harness earns its keep; Phase 4 records the mechanism decisions as
ADR-0003. Phase 1 and Phase 2 are independent of each other and could be
done in either order; Phase 3 needs both.

**Decisions this plan makes** (each also lands in ADR-0003, Phase 4):

1. **No `nimble_options`.** Two option keys do not justify a runtime
   dependency ADR-0002 decision 5 does not contemplate. `setup/1` validates
   by hand into a `%Config{}` struct and returns `{:error, reason}` on a bad
   key or value, which is the project's errors-are-events convention
   applied to a real evaluation.
2. **One handler id per event name**, `{OpentelemetryStatifier, event_name}`,
   attached with 27 `:telemetry.attach/4` calls rather than one
   `attach_many/4`. `attach_many/4`'s detach is total across the name list
   (`deps/telemetry/src/telemetry.erl:109-116`), so a single malformed
   `:datamodel_init` would take the macrostep spans down with it for the
   VM's lifetime. Per-event ids bound that blast radius to one event name,
   and `events/0` makes the enumeration free at both attach and detach.
   This is oban's and ecto's shape, not bandit's.
3. **`setup/1` is idempotent and returns `:ok`.** It detaches the package's
   own ids before attaching, so a second call with different options
   replaces the first rather than returning `{:error, :already_exists}`. The
   family disagrees here and two of the three variants contradict their own
   `@spec`, so this is decided rather than copied. `teardown/0` ships in
   `lib/` (the `opentelemetry_absinthe` precedent) because the alternative
   is every consumer's test suite writing the same `on_exit` detach loop.
4. **The ETS table is owned by a supervised process**,
   `OpentelemetryStatifier.SpanTable`, started by a new
   `OpentelemetryStatifier.Application` added as `mod:` in `mix.exs`. A
   table created in `setup/1` would be owned by whichever process happened
   to call it - `opentelemetry_ecto`'s latent bug. Ownership by the OTP
   application means the table exists before any handler can fire, survives
   every session process, and gives ots-lt6's sweep timer a natural home.
   The cost is one idle process in a host that never calls `setup/1`, which
   is the normal shape for instrumentation packages.
5. **The table is `:public` and `:named_table`**, and the table name rides
   in the handler `Config` so tests can inject their own private table
   (`OpentelemetryRedix.ConnectionTracker`'s pattern). Handlers write
   directly from the session process; nothing goes through the owner
   process, so the owner is never a bottleneck on the macrostep path.
6. **Two logical slots, one table, tagged keys.** `{:span, span_ref}` for
   open spans - `span_ref` and not `session_id`, because st-ADR-0039 re-entry
   means one session can have two spans open at once - and
   `{:last_span_ctx, session_id}` for the link slot the design note
   describes per session. `session_id` is denormalised into element 2 of
   both row shapes so ots-lt6 can sweep a session with one
   `:ets.match_delete/2` without decoding structs.
7. **No `opentelemetry_telemetry` dependency.** It is the family's canonical
   answer to the start-handler/stop-handler problem, so the omission needs a
   reason: it stores span contexts in the **process dictionary**, keyed on
   `metadata.telemetry_span_context` or, absent that, a per-tracer stack its
   own moduledoc describes as reducing "the likelihood of inadvertently
   closing the wrong span" rather than preventing it. Statifier hands the
   bridge an exact `span_ref`, and the last-span-context slot needs a table
   the process dictionary cannot supply anyway. Rolling the pairing here is
   strictly better informed and adds no runtime dependency.
8. **Spans start from a fresh `OpenTelemetry.Ctx.new()`**, never from the
   process's ambient context, and are never attached to the process context.
   That is what makes each macrostep a root span (the design note's "one
   trace per macrostep"), and it also means the bridge cannot clobber a
   host's context inside the session process.
9. **`statifier.configuration` is set on the stop.** The bead's wording
   names "trigger/event_name/outcome/counters", but `configuration` is on
   the same event, is already resolved to state-id strings by the contract
   (`deps/statifier/lib/statifier/session/telemetry.ex:713-718`), and the
   design note maps it to a string-array attribute explicitly bounded by
   chart size. Leaving it for ots-j82 would mean touching the same handler
   clause twice. It is `MapSet.to_list/1 |> Enum.sort/1` for deterministic
   assertions.

---

## Phase 1: setup/1, option validation, and a surviving handler

### Overview

Make `setup/1` real: validate options into a struct, attach one handler per
event name, and give the handler a body that recognises nothing yet and
survives everything. No spans, no table.

### Changes Required:

#### 1. The config struct
**File**: `lib/opentelemetry_statifier/config.ex` (new)
**Changes**: A struct carrying the validated setup options plus the ETS
table name (the field is defined here and defaults to the module name;
Phase 2 makes it meaningful).

```elixir
defmodule OpentelemetryStatifier.Config do
  @moduledoc "..."

  defstruct record_datamodel_values: false,
            table: OpentelemetryStatifier.SpanTable

  @type t :: %__MODULE__{
          record_datamodel_values: boolean(),
          table: atom()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    # explicit per-key validation; unknown keys are an error, not ignored
  end

  def new(_opts), do: {:error, {:invalid_options, :not_a_keyword_list}}
end
```

The `:table` field is an ETS **table name** - a bare atom, not a module
reference - so Phase 1 compiles and gates green before
`OpentelemetryStatifier.SpanTable` exists. Phase 2 gives that name a table.

`new/1` returns `{:error, {:invalid_option, key, value}}` for a bad value
and `{:error, {:unknown_options, keys}}` for keys outside the two. Unknown
keys are rejected rather than ignored: a typo'd `record_datamodel_value`
silently doing nothing is exactly the failure the cardinality policy cannot
afford.

#### 2. The handler module
**File**: `lib/opentelemetry_statifier/handler.ex` (new)
**Changes**: `handle_event/4` with a single final catch-all clause for now.
The moduledoc records why there is no `try/rescue`.

```elixir
defmodule OpentelemetryStatifier.Handler do
  @moduledoc "..."

  @spec handle_event(:telemetry.event_name(), map(), map(), Config.t()) :: :ok
  # Phases 3 adds the two macrostep clauses above this one. The catch-all is
  # the defensive boundary: :telemetry detaches a handler that raises, and
  # under a per-event id that would silently kill one event name for the
  # VM's lifetime. Clause exhaustiveness, not rescue-to-default.
  def handle_event(_event, _measurements, _metadata, _config), do: :ok
end
```

#### 3. The public API
**File**: `lib/opentelemetry_statifier.ex`
**Changes**: Replace the placeholder `setup/0` with `setup/0`, `setup/1`,
`teardown/0` and a private `handler_id/1`. Keep a doctest.

```elixir
@spec setup() :: :ok | {:error, term()}
def setup, do: setup([])

@spec setup(keyword()) :: :ok | {:error, term()}
def setup(opts) do
  with {:ok, config} <- Config.new(opts) do
    :ok = teardown()

    Enum.each(Telemetry.events(), fn event ->
      :telemetry.attach(handler_id(event), event, &Handler.handle_event/4, config)
    end)
  end
end

@spec teardown() :: :ok
def teardown do
  Enum.each(Telemetry.events(), &:telemetry.detach(handler_id(&1)))
end

defp handler_id(event), do: {__MODULE__, event}
```

The capture is a remote function capture, per `:telemetry`'s own performance
note (`deps/telemetry/src/telemetry.erl:112-116`).

#### 4. Tests
**File**: `test/opentelemetry_statifier_test.exs`
**Changes**: Replace the placeholder test. Each test asserting `lib/`
behavior gets its `# sabotage:` line, verified by actually breaking the code
and watching it go red.

Coverage: `setup/1` attaches to all 27 names (compare
`:telemetry.list_handlers([:statifier])` ids against
`Statifier.Session.Telemetry.events/0` by pattern match, not by count
alone); `setup/1` twice returns `:ok` and still leaves exactly 27 handlers;
`setup/1` with `record_datamodel_values: true` puts it in the handler
config; `setup/1` with an unknown key returns `{:error, {:unknown_options,
[...]}}` and attaches nothing; `setup/1` with a non-boolean value returns
`{:error, {:invalid_option, ...}}`; `teardown/0` leaves none; the handler
survives an event with garbage measurements and metadata (execute a
`[:statifier, :session, :trace, :done]` with `%{}`/`%{}` and assert the
handler is still attached afterwards - that is the assertion that actually
proves the boundary, since a raise would have detached it).

`on_exit(&OpentelemetryStatifier.teardown/0)` in `setup`, and the test file
is `async: false` because `:telemetry`'s handler registry is global.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes (`mix quality`), including credo `--strict`,
      dialyzer, `warnings_as_errors` and the 90% coverage floor
- [x] `test/opentelemetry_statifier_test.exs` covers all seven cases above
- [x] Every new `test "..."` in the file has a `# sabotage:` line directly
      above it (a grep can decide this; whether the mutation was really run
      is the manual item below)

#### Manual Verification:
- [ ] Each sabotage line was produced by actually breaking the `lib/` code
      it names, running the suite, observing red, and reverting - the
      comment is the record of that, not a substitute for it
- [ ] The `{:error, ...}` shapes read usefully at a host's call site
- [ ] `iex -S mix` then `OpentelemetryStatifier.setup()` followed by
      `:telemetry.list_handlers([:statifier])` shows 27 entries with the
      expected id shape
- [ ] No regressions: the package still starts in a host that never calls
      `setup/1`

**Implementation Note**: Use `mix quality --profile loop` between edits and
`mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 2: The supervised span table

### Overview

Stand up the ETS table and the process that owns it, with the row shapes
Phase 3 writes and ots-j82/ots-lt6 read. No telemetry involvement.

### Changes Required:

#### 1. The span entry struct
**File**: `lib/opentelemetry_statifier/span_entry.ex` (new)
**Changes**: What an open span row holds.

```elixir
defmodule OpentelemetryStatifier.SpanEntry do
  @moduledoc "..."

  @enforce_keys [:session_id, :span_ctx, :trigger, :started_at]
  defstruct [:session_id, :span_ctx, :trigger, :started_at]

  @type t :: %__MODULE__{
          session_id: String.t(),
          span_ctx: OpenTelemetry.span_ctx(),
          trigger: atom(),
          started_at: integer()
        }
end
```

`started_at` is the `monotonic_time` the span was opened with - ots-lt6's
sweep needs an age, and recomputing it from the span ctx is not possible
through the API.

#### 2. The table owner
**File**: `lib/opentelemetry_statifier/span_table.ex` (new)
**Changes**: A GenServer that creates the table in `init/1` and otherwise
does nothing, plus the pure read/write functions the handlers call directly
against the table. Session-first argument order per the project convention
where a function takes one.

```elixir
defmodule OpentelemetryStatifier.SpanTable do
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()

  # created :public so handlers write from the session process with no
  # message hop; :named_table so the default needs no lookup. The name is
  # a parameter so tests can run against their own table.
  @spec new_table(atom()) :: atom()

  @spec put_open_span(atom(), reference(), SpanEntry.t()) :: :ok
  @spec take_open_span(atom(), reference()) :: {:ok, SpanEntry.t()} | :error
  @spec put_last_span_ctx(atom(), String.t(), OpenTelemetry.span_ctx()) :: :ok
  @spec fetch_last_span_ctx(atom(), String.t()) ::
          {:ok, OpenTelemetry.span_ctx()} | :error
end
```

Row shapes, fixed here because two other beads read them:

```
{{:span, span_ref},              session_id, %SpanEntry{}}
{{:last_span_ctx, session_id},   session_id, span_ctx}
```

`take_open_span/2` is `lookup` + `delete` (not `:ets.take/2`, which returns
a list) and returns `:error` rather than raising on a miss - a stop with no
matching start is a contract-legal shape, not a bug.

`session_id` is duplicated into element 2 of both rows so ots-lt6 can do
`:ets.match_delete(table, {:_, session_id, :_})`.

#### 3. The application
**File**: `lib/opentelemetry_statifier/application.ex` (new) and `mix.exs`
**Changes**: A supervisor with `SpanTable` as its only child, and
`mod: {OpentelemetryStatifier.Application, []}` added to `application/0` in
`mix.exs:29-33`.

#### 4. Tests
**File**: `test/opentelemetry_statifier/span_table_test.exs` (new)
**Changes**: `async: true`, each test creating its own table via
`new_table/1` with a unique name, so nothing depends on the application
table.

Coverage: put then take round-trips a `%SpanEntry{}` and the second take
returns `:error`; two entries for one `session_id` under different
`span_ref`s coexist and are taken independently (the re-entry shape, at the
table level); `fetch_last_span_ctx/2` returns `:error` for an unknown
session and the last value written for a known one; the row shape is what
ots-lt6 expects (`:ets.match_object(table, {:_, session_id, :_})` finds both
kinds of row for a session); the application-started table exists and is
named (one test against `OpentelemetryStatifier.SpanTable`).

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes (`mix quality`)
- [x] `test/opentelemetry_statifier/span_table_test.exs` covers all five
      cases above and passes with `async: true`
- [x] Every new `test "..."` in the file has a `# sabotage:` line directly
      above it
- [x] Dialyzer accepts the `OpenTelemetry.span_ctx()` types in the struct

#### Manual Verification:
- [ ] Each sabotage line was produced by actually running the mutation it
      names and observing red, then reverting
- [ ] `iex -S mix` shows the table present at boot without calling `setup/1`
- [ ] Killing the `SpanTable` process shows the supervisor restarting it and
      the table being recreated (empty), rather than the VM losing the table
      permanently
- [ ] The `mod:` addition does not disturb a host that only wants the API

**Implementation Note**: Use `mix quality --profile loop` between edits and
`mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 3: Macrostep spans paired on span_ref

### Overview

The slice's substance: the two macrostep clauses in the handler, the
attribute mapping, and the SDK capture harness that proves it.

### Changes Required:

#### 1. Test support: in-process span capture
**File**: `test/support/span_capture.ex` (new), `config/test.exs`,
`test/test_helper.exs`
**Changes**: Flavor A of the family's two testing shapes, which
`config/test.exs`'s existing comment already commits this repo to.

`config/test.exs` gains `config :opentelemetry, processors: [{:otel_simple_processor, %{}}]`
alongside the existing `traces_exporter: :none`.

```elixir
defmodule OpentelemetryStatifier.SpanCapture do
  @moduledoc false

  require Record

  for {name, spec} <- Record.extract_all(from_lib: "opentelemetry/include/otel_span.hrl") do
    Record.defrecord(name, spec)
  end

  # attach the pid exporter to the caller and detach the bridge on exit
  def start(_context), do: ...
end
```

`test/support/` is already on the test compile path (`mix.exs:36`) and
skipped by `coveralls.json`, so this module does not dilute the 90% floor.

#### 2. The macrostep start clause
**File**: `lib/opentelemetry_statifier/handler.ex`
**Changes**: A clause matching the start event with every key it needs bound
in the head - a start missing `span_ref` or `monotonic_time` falls to the
catch-all and is dropped.

```elixir
require OpenTelemetry.Tracer

def handle_event(
      [:statifier, :session, :macrostep, :start],
      %{monotonic_time: monotonic_time},
      %{session_id: session_id, trigger: trigger, span_ref: span_ref} = metadata,
      %Config{table: table}
    )
    when is_reference(span_ref) and is_integer(monotonic_time) do
  span_ctx =
    OpenTelemetry.Tracer.start_span(
      OpenTelemetry.Ctx.new(),
      "statifier.macrostep",
      %{start_time: monotonic_time, attributes: start_attributes(session_id, trigger, metadata)}
    )

  SpanTable.put_open_span(table, span_ref, %SpanEntry{
    session_id: session_id,
    span_ctx: span_ctx,
    trigger: trigger,
    started_at: monotonic_time
  })
end
```

`OpenTelemetry.Ctx.new()` (an empty map) is what makes the span a root, per
the design note's one-trace-per-macrostep. The span is deliberately **not**
made current in the process - it is not lexically scoped, and attaching it
would clobber a host's context inside the session process.

Start attributes: `"statifier.session_id"`, `"statifier.trigger"`
(`Atom.to_string/1`), and `"statifier.event_name"` **only when non-nil** -
`event_name` is `nil` on every `:initialize`, `:cancel` and `:resume` span
(`deps/statifier/lib/statifier/session/telemetry.ex:720-722`), and an
absent attribute is cleaner than a `"nil"` string.

#### 3. The macrostep stop clause
**File**: `lib/opentelemetry_statifier/handler.ex`
**Changes**:

```elixir
def handle_event(
      [:statifier, :session, :macrostep, :stop],
      %{monotonic_time: monotonic_time} = measurements,
      %{span_ref: span_ref} = metadata,
      %Config{table: table}
    )
    when is_reference(span_ref) and is_integer(monotonic_time) do
  case SpanTable.take_open_span(table, span_ref) do
    {:ok, %SpanEntry{span_ctx: span_ctx, session_id: session_id}} ->
      OpenTelemetry.Span.set_attributes(span_ctx, stop_attributes(measurements, metadata))
      ended = OpenTelemetry.Span.end_span(span_ctx, monotonic_time)
      SpanTable.put_last_span_ctx(table, session_id, ended)

    :error ->
      :ok
  end
end
```

Stop attributes: `"statifier.outcome"`, `"statifier.duration"`,
`"statifier.macrostep"`, `"statifier.microsteps"`, `"statifier.rounds"`,
`"statifier.event_name"` (when non-nil), and `"statifier.configuration"` as
a sorted string list from the `MapSet`. Every measurement read is
defensive - a missing counter is omitted, built by a private
`put_when/3`-style helper with a total signature rather than by
`Map.fetch!/2`.

A stop with no matching start (`:error`) is silently ignored: the contract
publishes unmatched halves as legal (`deps/statifier/lib/statifier/session/telemetry.ex:64-70`).

`end_span/2` is `OpenTelemetry.Span.end_span/2` - the ctx-explicit form, and
it returns the ended ctx which is exactly what the link slot and ots-lt6's
`set_status/2` want.

#### 4. Tests
**File**: `test/opentelemetry_statifier/handler_test.exs` (new)
**Changes**: `async: false` (global handler registry and a shared exporter
pid), driving `:telemetry.execute/3` by hand with hand-built measurement and
metadata maps rather than running a real session - the events are the
contract, and constructing them directly is what keeps the test honest
about consuming only public shapes.

Coverage, each a single `assert_receive {:span, span(...)}` pattern match
rather than a pile of asserts:

- a start/stop pair emits one span named `"statifier.macrostep"` carrying
  the session id, trigger, event name, outcome, the three counters,
  `duration` and the sorted configuration list
- the span's start and end timestamps are exactly the `monotonic_time`
  values fed in (this is the test that would catch a `system_time` slip)
- each macrostep span is a root: `parent_span_id` is `:undefined`, and two
  successive pairs for one session have different trace ids
- re-entry - `start(A), start(B), stop(B), stop(A)` on one `session_id` -
  emits two spans, and the one closed first is B's, matched by its
  attributes; neither span is the other's parent
- a start with no stop emits nothing and leaves a row in the table
- a stop with an unknown `span_ref` emits nothing and does not raise
- a start missing `span_ref` (or with a non-reference one) emits nothing and
  the handler is still attached afterwards
- after a stop, `SpanTable.fetch_last_span_ctx/2` returns the ended span ctx
  for that session
- an `:initialize` trigger with `event_name: nil` emits a span with no
  `statifier.event_name` attribute at all
- all five `trigger` values (`:initialize | :event | :cancel | :internal |
  :resume`) round-trip as strings

Each carries its verified `# sabotage:` line. The re-entry test's sabotage
is the load-bearing one: pairing on `session_id` instead of `span_ref`
must turn it red.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes (`mix quality`)
- [x] `test/opentelemetry_statifier/handler_test.exs` covers all ten cases
      above
- [x] Every new `test "..."` in the file has a `# sabotage:` line directly
      above it, and the re-entry test's line reads "pair on session_id ->
      red"
- [x] Coverage stays above the 90% floor with `test/support/` excluded

#### Manual Verification:
- [ ] Each sabotage line was produced by actually running the mutation it
      names and observing red, then reverting. The re-entry test is the one
      that matters most: swapping `span_ref` pairing for `session_id`
      pairing must genuinely fail it
- [ ] A real `Statifier.Session` run in `iex` with the bridge set up and a
      console exporter produces spans that look right end to end, including
      an `:initialize` span whose late start is the known accepted skew
- [ ] Span attributes render sensibly in a backend's UI (names, types,
      the configuration array)
- [ ] With no SDK configured, the same run produces no spans and no errors -
      the noop tracer path
- [ ] No regressions: the 25 unmapped events still no-op

**Implementation Note**: Use `mix quality --profile loop` between edits and
`mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 4: ADR-0003 and the public docs

### Overview

Record the mechanism decisions. ADR-0002's Consequences says handler
modules, ETS ownership and the setup API are this repository's decisions and
belong in "future ADRs here"; this phase writes that one. Docs only.

### Changes Required:

#### 1. The ADR
**File**: `docs/adr/0003-handler-attach-and-span-table-mechanism.md` (new)
**Changes**: Context, Decision, Consequences in the shape ADR-0001 sets, and
using the family's cross-repo citation convention (`st-ADR-NNNN` for
statifier-ex, bare `ADR-NNNN` here). The decisions are items 1 through 9 in
this plan's Implementation Approach, each with its one-line rationale -
check every ADR number as you copy them across: the re-entry rule item 6
cites is statifier-ex's `st-ADR-0039`, and there is no local ADR-0039 for a
bare citation to resolve to.
Consequences record what it constrains: ots-lt6 inherits the table's row
shapes and the `SpanTable` process as the sweeper's home; ots-j82 inherits
the `Config` struct as the `record_datamodel_values` carrier and the
`:last_span_ctx` slot; and open-span rows accumulate until ots-lt6 lands.

#### 2. Docs index and README
**File**: `docs/adr/README.md`, `README.md`,
`lib/opentelemetry_statifier.ex`
**Changes**: Add ADR-0003 to the index. Replace the moduledoc's "Nothing is
implemented yet" with what `setup/1` now does, and give the README a usage
snippet. The doctest stays green because `setup/0` still returns `:ok`.

Prose in new files here is plain ASCII punctuation, matching both this
repo's existing documents and the personal default.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes (`mix quality`) - the doctest in the rewritten
      moduledoc still passes
- [x] `docs/adr/0003-handler-attach-and-span-table-mechanism.md` exists and
      is listed in `docs/adr/README.md`

#### Manual Verification:
- [ ] The ADR reads as a decision record, not a restatement of the design
      note - it defers to statifier-ex on mapping and decides only mechanism
- [ ] `mix docs` output reads correctly for a first-time consumer
- [ ] Nothing in the ADR contradicts ADR-0002 or the upstream design note

**Implementation Note**: Use `mix quality --profile loop` between edits and
`mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Testing Strategy

### Unit Tests:

- `test/opentelemetry_statifier_test.exs` (`async: false`) - the setup API:
  attach coverage against `events/0`, idempotence, option validation
  failures, teardown, and the boundary test that garbage in an event leaves
  the handler attached.
- `test/opentelemetry_statifier/span_table_test.exs` (`async: true`, private
  tables per test) - row shapes, take semantics, two open spans for one
  session, the last-span-ctx slot, and the match shape ots-lt6 will use.
- `test/opentelemetry_statifier/handler_test.exs` (`async: false`, pid
  exporter) - span emission, timestamps, root-ness, re-entry pairing,
  unmatched halves, malformed events, the nil `event_name` case, and the
  five `trigger` values.
- `test/support/span_capture.ex` - the exporter harness, excluded from
  coverage.

Key edge cases, all covered above: re-entry nesting; a start with no stop; a
stop with no start; `event_name: nil`; a malformed event; and the no-SDK
noop path (manual in this plan, automated by ots-lt6's degradation test).

**Sabotage discipline.** Every test in every phase that asserts `lib/`
behavior must be sabotage-verified: break the code it covers, run the suite,
confirm red, revert, and write the one-line
`# sabotage: <what was broken> -> red` comment above the test. This is a
phase requirement, not a cleanup pass - a phase whose tests lack verified
sabotage lines is not done. The re-entry test is the one where sabotage is
substantive rather than ceremonial: swapping `span_ref` pairing for
`session_id` pairing must make it fail.

### Manual Testing Steps:

1. `iex -S mix` and confirm the `SpanTable` table exists at boot without
   calling `setup/1`.
2. `OpentelemetryStatifier.setup()` then `:telemetry.list_handlers([:statifier])` -
   27 handlers with `{OpentelemetryStatifier, event}` ids.
3. Configure a console exporter, run a real `Statifier.Session` through a
   small chart, and inspect the emitted `statifier.macrostep` spans:
   attributes present and typed, one trace per macrostep, the `:initialize`
   span's start late by the accepted skew.
4. Repeat with no SDK started - no spans, no errors, no log noise.
5. `OpentelemetryStatifier.teardown()` and confirm the handler list is empty
   and a subsequent session emits nothing.

## Open Questions Carried Forward

The research pass recorded nine open questions and no human was available to
answer them. Seven are decided in this plan's Implementation Approach
(items 1-9 map to research questions 3, 5, 4, 6, 6, 7, 8, plus the span-root
and configuration decisions), and research question 9 - the
`record_exception` / `set_status` asymmetry - is answered structurally by
Phase 2 storing the `span_ctx` that ots-lt6's `set_status/2` needs.

Two remain genuinely open, both upstream, and **neither blocks this plan**:

1. **Whether to advance the statifier pin.** `mix.lock` pins
   `fe77a8249f58e463c69634987ab2000101a152cf`, which predates both
   `docs/opentelemetry.md` and st-ADR-0062 - this plan read both from the
   sibling checkout at `/Users/johnnyt/repos/github/statifier-ex`. The event
   shapes the bridge consumes *are* in the pinned tree, so the slice is
   implementable as pinned. Advancing the pin is a human call under
   st-ADR-0061 and is not taken here. Until it moves, anyone reading
   `deps/statifier/docs/` for the design note will not find it.

   **Tracked (2026-08-21):** filed as `ots-nxl`.

2. **The design note enumerates four `trigger` values, the code emits five.**
   `docs/opentelemetry.md:73-74` upstream lists
   `initialize | event | cancel | internal`; the pinned specs
   (`deps/statifier/lib/statifier/session/telemetry.ex:358,388`) and
   `boot/6` also emit `:resume`, added by st-ADR-0060. The attribute is a
   pass-through string either way, so nothing here breaks; this plan's tests
   enumerate five. Under CLAUDE.md's cross-repo table the correction is
   statifier-ex's to make, and it should be raised there rather than
   patched around here.

   **Tracked (2026-08-21):** filed as `ots-2bs` (label `upstream`).

## References

- Source document: `docs/research/260820-ots-fhc-setup-api-and-macrostep-spans.md`
- Related ADRs: `docs/adr/0001-record-architecture-decisions.md`,
  `docs/adr/0002-adopts-the-upstream-bridge-contract.md`; upstream
  st-ADR-0040, st-ADR-0061, st-ADR-0062
- Design note (upstream, not in the pinned dep):
  `/Users/johnnyt/repos/github/statifier-ex/docs/opentelemetry.md:64-203`
- Event contract: `deps/statifier/lib/statifier/session/telemetry.ex:33-78`
  (span correlation and consumer caveats), `:112-135` (the event table),
  `:225-273` (`events/0`), `:356-373` and `:386-414` (the two emitters)
- OTel API surface: `deps/opentelemetry_api/lib/open_telemetry/tracer.ex:45`
  (`start_span/3`), `deps/opentelemetry_api/src/otel_span.erl:47-52`
  (`start_opts`), `deps/opentelemetry_api/lib/open_telemetry/span.ex:87-193`
  (the ctx-explicit functions),
  `deps/opentelemetry_api/src/opentelemetry.erl:328-330` (`timestamp/0`)
- `:telemetry` mechanics: `deps/telemetry/src/telemetry.erl:102-116`,
  `:196-215`
- Similar implementations: `OpentelemetryRedix.ConnectionTracker` (owned
  table, name in handler config), `opentelemetry_ecto` (per-event handler
  ids; also the unowned-table anti-pattern), `otel_telemetry.erl` (the
  catch-all defensive clause shape)
- Bead: `ots-fhc`; siblings `ots-j82`, `ots-lt6`, `ots-6ns`; epic `ots-8wp`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [x] Each sabotage line was produced by actually breaking the `lib/` code
      it names, running the suite, observing red, and reverting - the
      comment is the record of that, not a substitute for it
- [x] The `{:error, ...}` shapes read usefully at a host's call site
- [x] `iex -S mix` then `OpentelemetryStatifier.setup()` followed by
      `:telemetry.list_handlers([:statifier])` shows 27 entries with the
      expected id shape
- [x] No regressions: the package still starts in a host that never calls
      `setup/1`

**Implementation Note**: Use `mix quality --profile loop` between edits and
`mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

### Phase 2

- [x] Each sabotage line was produced by actually running the mutation it
      names and observing red, then reverting
- [x] `iex -S mix` shows the table present at boot without calling `setup/1`
- [x] Killing the `SpanTable` process shows the supervisor restarting it and
      the table being recreated (empty), rather than the VM losing the table
      permanently
- [x] The `mod:` addition does not disturb a host that only wants the API

**Implementation Note**: Use `mix quality --profile loop` between edits and
`mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

### Phase 3

- [x] Each sabotage line was produced by actually running the mutation it
      names and observing red, then reverting. The re-entry test is the one
      that matters most: swapping `span_ref` pairing for `session_id`
      pairing must genuinely fail it
- [x] A real `Statifier.Session` run in `iex` with the bridge set up and a
      console exporter produces spans that look right end to end, including
      an `:initialize` span whose late start is the known accepted skew
- [x] Span attributes render sensibly in a backend's UI (names, types,
      the configuration array)
- [x] With no SDK configured, the same run produces no spans and no errors -
      the noop tracer path
- [x] No regressions: the 25 unmapped events still no-op

**Implementation Note**: Use `mix quality --profile loop` between edits and
`mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

### Phase 4

- [x] The ADR reads as a decision record, not a restatement of the design
      note - it defers to statifier-ex on mapping and decides only mechanism
- [x] `mix docs` output reads correctly for a first-time consumer
- [x] Nothing in the ADR contradicts ADR-0002 or the upstream design note

**Implementation Note**: Use `mix quality --profile loop` between edits and
`mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---
