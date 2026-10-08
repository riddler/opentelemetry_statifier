# Upgrading a host from 0.6 to 0.9

This page says what a host changes to move `opentelemetry_statifier` from
0.6.0 to 0.9.1, one minor at a time: 0.6 to 0.7, 0.7 to 0.8 and 0.8 to
0.9, then the 0.9.1 patch. A host here is the code that embeds the
package: its calls to `OpentelemetryStatifier.setup/1`,
`OpentelemetryStatifier.Persistence.setup/0,1` and
`OpentelemetryStatifier.Oban.setup/0,1`, and the saved queries, dashboards
and alerts it keeps in its tracing backend over the spans they export.
What each release added is in [CHANGELOG.md](../CHANGELOG.md); this page
lists only what a host has to do about it, and says **NONE** where the
answer is nothing.

Move the pin with each minor, as the README recommends:
`{:opentelemetry_statifier, "~> 0.9.0"}`. The package's requirements
(`statifier ~> 2.4`, `opentelemetry_api ~> 1.4`, `telemetry ~> 1.0`) are
the same on every step of this page, and so are `setup/1` and its options:
`record_datamodel_values` still defaults to `false`. The `Persistence` and
`Oban` bridges still take no dependency on `statifier_persistence` or
`statifier_oban`. Each attaches to the names its own `events/0` lists, so
a name the host's release of the sibling does not emit is never heard, and
nothing fails.

## 0.6 to 0.7

0.7.0 bridges four `statifier_persistence` events that 0.6.0 attached
nothing to: `[:statifier_persistence, :execution, :step, :exception]`,
`[..., :step, :reentered]`, `[..., :execution, :migrated]` and
`[..., :execution, :unparked]`. `OpentelemetryStatifier.Persistence.events/0`
grows from 16 names to 20.

Must change: **NONE**. Every span, span event and attribute 0.6.0 exported
keeps its name and its shape.

- **If you look for failed durable steps in your backend**, a step that
  raises, throws or exits now ends its `statifier_persistence.execution.step`
  span with an error status whose message is `"<kind>: <reason>"`
  (`"error: RuntimeError"`), and carries `kind` and `reason` as
  attributes. 0.6.0 attached nothing to that event, so the raise did not
  close the step span with an error status.
- **If you will stop at 0.7 for a while**, a migrated execution is now a
  `statifier_persistence.execution.migrated` point carrying a
  `statifier_persistence.dropped` attribute, and at 0.7.0 that attribute is
  one `inspect/1` string (`"[]"` when nothing was dropped). 0.8.0 changes
  its shape (the next section). A host going straight on to 0.8 writes any
  query on `dropped` against the 0.8 shape and never needs this one.

## 0.7 to 0.8

0.8.0 makes three changes: the `dropped` attribute's shape, one more
`statifier_oban` event bridged, and an `exception` span event on a
failing step. `OpentelemetryStatifier.Oban.events/0` grows from 14 names
to 15.

Must change: **NONE** for a host with no query, alert or code that reads
`statifier_persistence.dropped`. Every other attribute keeps its value.

- **If you parse or match the `statifier_persistence.dropped` string**,
  read it as an array instead. On the
  `statifier_persistence.execution.migrated` point it is now a sorted array
  of the dropped state ids, the shape `statifier.configuration` has, so a
  query for one state id matches an element of the array rather than a
  substring of `["on_loan", "renewing"]`.
- **If you match `dropped` against `"[]"`** to find the migrations that
  dropped nothing, check for the attribute's absence instead. A migration
  that drops no state now carries no `statifier_persistence.dropped`
  attribute at all, because the OpenTelemetry API refuses an empty array.
- **If you run the Oban bridge and an invoke handler of yours answers
  `:deferred`** (`statifier_oban` 0.15.0 and later emit
  `[:statifier_oban, :invoke, :deferred]` for it), each such invocation
  now gets a `statifier_oban.invoke.deferred` span: a root of its own, not
  linked, correlated by `statifier.session_id`, like the
  `statifier_oban.invoke.delivered` span. It is the last span the bridge
  produces for that invocation; the answer your handler delivers later
  produces none here. Under 0.7.0 a deferred invocation got no span.
- **If you read failed durable steps in your backend's exception view**,
  the step span a raise, throw or exit closes now carries an `exception`
  span event with `exception.type` (`"Elixir.RuntimeError"` for an
  `:error`, `"<kind>:<reason>"` for a throw or an exit) and
  `exception.stacktrace`, the frames `statifier_persistence` narrowed,
  one per line. There is no `exception.message`. The span's error status
  message and its `kind` and `reason` attributes are unchanged from 0.7.0.

## 0.8 to 0.9

0.9.0 bridges `statifier_persistence`'s batch migration span:
`[:statifier_persistence, :execution, :migrate_batch, :start]`,
`[..., :stop]` and `[..., :exception]`, which `statifier_persistence`
0.20.0 and later emit around a
`StatifierPersistence.Executions.migrate_batch/3` call.
`OpentelemetryStatifier.Persistence.events/0` grows from 20 names to 23.

Must change: **NONE** for a host that never calls `migrate_batch/3`. A
migration through `StatifierPersistence.Executions.migrate/4` outside a
batch exports the same `statifier_persistence.execution.migrated` point
as at 0.8.0.

- **If you call `migrate_batch/3` and your queries, dashboards or alerts
  find its executions' spans as trace roots**, look under the batch span
  instead. Each call, a dry run included, is now one
  `statifier_persistence.execution.migrate_batch` span. Each execution the
  batch moves is a `statifier_persistence.execution.migrated` span event
  on it, where it was a zero-duration root span of its own, and the
  `statifier_persistence.execution.lock` and
  `statifier_persistence.adapter.call` spans each execution's turn opens
  nest under it, where they were roots. A dry run's batch span carries no
  `migrated` event.

May start doing:

- **Read a batch's outcome from its span.** The batch span carries the
  plan's two content hashes (`statifier_persistence.from`,
  `statifier_persistence.to`), `statifier_persistence.dry_run`, and on the
  close one integer attribute per outcome of the mode with the report's
  count, zeros included (`statifier_persistence.migrated` among them for
  an apply, `statifier_persistence.would_migrate` for a dry run). The
  `OpentelemetryStatifier.Persistence` documentation lists them.

## 0.9.0 to 0.9.1

Must change: **NONE**. 0.9.1 is documentation only: no module, function,
event or attribute changes.
