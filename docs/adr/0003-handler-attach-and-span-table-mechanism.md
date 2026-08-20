# ADR-0003: Handler attach and span table mechanism

Status: accepted (2026-08-20)

Cross-repo citations here use the family convention: a beads-prefix
qualifier on the ADR number (`st-ADR-0039` is statifier-ex's ADR-0039; a
bare `ADR-NNNN` is always this repository's own).

## Context

ADR-0002's Consequences license this repository to decide, on its own
authority, "handler modules, ETS span-table ownership, sweeper design, and
the setup API." `ots-fhc` is the first slice that has to actually make
those decisions: `OpentelemetryStatifier.setup/1` attaching to all 27 names
`Statifier.Session.Telemetry.events/0` returns, and the macrostep
`:start`/`:stop` pair becoming one `statifier.macrostep` span. Nine
mechanism choices came out of that work. Each is a real fork - a documented
family precedent existed and was rejected, or the codebase offered a
shortcut that was declined - so each is recorded here rather than left to
be reverse-engineered from the code later.

## Decision

1. **No `nimble_options`.** Two option keys do not justify a runtime
   dependency ADR-0002 decision 5 does not contemplate.
   `OpentelemetryStatifier.Config.new/1` validates by hand and returns
   `{:error, reason}` on a bad key or value - the project's
   errors-are-events convention applied to a real evaluation.
2. **One handler id per event name**, `{OpentelemetryStatifier, event_name}`,
   attached with 27 `:telemetry.attach/4` calls rather than one
   `attach_many/4`. `attach_many/4`'s detach is total across the whole name
   list, so a single malformed event would take every event - including
   the macrostep spans - down with it for the VM's lifetime. Per-event ids
   bound that blast radius to one event name.
3. **`setup/1` is idempotent, detaches its own ids before attaching, and
   returns `:ok`.** A second call - with the same or different options -
   replaces the first attachment rather than returning an
   already-exists error. `teardown/0` ships in `lib/`, because the
   alternative is every consumer's test suite writing the same `on_exit`
   detach loop.
4. **The ETS table is owned by a supervised process**,
   `OpentelemetryStatifier.SpanTable`, started by
   `OpentelemetryStatifier.Application`'s `mod:`. A table created inside
   `setup/1` would be owned by whichever process happened to call it.
   Ownership by the OTP application means the table exists before any
   handler can fire, survives every session process, and gives ots-lt6's
   sweep timer a natural home.
5. **The table is `:public` and `:named_table`**, and the table name rides
   in the handler `Config` so tests can inject their own private table.
   Handlers read and write the table directly from the session process;
   nothing goes through the owner process, so the owner is never a
   bottleneck on the macrostep path.
6. **Two logical slots, one table, tagged keys**: `{:span, span_ref}` for
   open spans and `{:last_span_ctx, session_id}` for the link slot the
   design note describes per session. The open-span row is keyed on
   `span_ref`, not `session_id`, because st-ADR-0039's re-entry rule means
   one session can have two macrostep spans open at once. `session_id` is
   denormalized into element 2 of both row shapes so a sweeper can find
   every row for a session with one `:ets.match_delete/2`, without
   decoding either row's structured value.
7. **No `opentelemetry_telemetry` dependency.** It is the family's
   canonical answer to the start-handler/stop-handler problem, but it
   stores span contexts in the process dictionary, keyed on
   `metadata.telemetry_span_context` or, absent that, a per-tracer stack
   its own moduledoc describes as reducing the likelihood of closing the
   wrong span rather than preventing it. Statifier hands the bridge an
   exact `span_ref`, and the last-span-context slot needs a table the
   process dictionary cannot supply anyway. Rolling the pairing here is
   strictly better informed and adds no runtime dependency.
8. **Spans start from a fresh `OpenTelemetry.Ctx.new/0`**, never from the
   process's ambient context, and are never attached to the process
   context. That is what makes each macrostep the root of its own trace
   (the design note's "one trace per macrostep"), and it also means the
   bridge cannot clobber a host's context inside the session process.
9. **`statifier.configuration` is set on the stop event**, not deferred to
   ots-j82. It is on the same event as the other stop attributes, is
   already resolved to state-id strings by the contract, and the design
   note maps it to a string-array attribute bounded by chart size.
   Deferring it would mean touching the same handler clause twice; it is
   written as `MapSet.to_list/1 |> Enum.sort/1` for deterministic
   assertions.

## Consequences

- **ots-lt6** inherits the table's row shapes and the `SpanTable` process
  as the sweeper's home: its `:terminate` cleanup and orphan sweep read
  and delete rows through the same table, under the same tagged keys,
  denormalized on `session_id` for exactly the reason decision 6 records.
- **ots-j82** inherits the `Config` struct as the carrier for
  `record_datamodel_values` (parsed and validated here, not yet read
  anywhere) and the `:last_span_ctx` slot (written here on every macrostep
  stop, not yet read anywhere) as the previous-macrostep link source.
- **Open-span rows accumulate.** Nothing in this slice deletes a `{:span,
  span_ref}` row for a `:start` that never gets a matching `:stop` - a
  crash mid-macrostep, or any session that never reaches `:stop`. This is
  a known, accepted gap, not a bug: ots-lt6 exists specifically to sweep
  these orphans and end them with an error status, and this plan
  deliberately does not duplicate that work.
- Nothing here revisits the design note's span topology or attribute
  mapping; those stay governed by ADR-0002 decision 3. What would reopen
  this record: the design note changing how macrostep spans are paired or
  scoped, or ots-lt6/ots-j82 discovering the row shapes decision 6 fixed do
  not actually serve their needs.
