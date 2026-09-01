defmodule OpentelemetryStatifier.SiblingEntry do
  @moduledoc """
  An open *sibling* span row held in `OpentelemetryStatifier.SpanTable`
  between a sibling package's `:start` event and the `:stop` whose
  `span_ref` matches - today only
  `[:statifier_persistence, :run, :step, :start | :stop]`, the one
  start/stop pair the sibling contracts define (sp-ADR-0009's step seam;
  `sob-ADR-0006` deliberately has no pairs).

  It is a separate row shape from `OpentelemetryStatifier.SpanEntry`
  because a sibling span is scoped to a *process*, not to a logical
  session: the step seam brackets one serialized drive on the calling
  process and knows a `run_id`, while `session_id` is `nil` until a
  position has been decoded. `pid` therefore rides in element 2 of the
  row (where the macrostep rows carry `session_id`), which is what lets
  the sweep find every sibling row for a dead process with one
  `:ets.match_object/2`, and what lets a macrostep span find the step
  span open around it in its own process.

  `ctx` is the OTel context with this span set as the current one. It is
  stored rather than rebuilt so a nested span - the durable macrostep
  span, an adapter-call span - starts from exactly this span without
  reading or writing the process's ambient context
  (`docs/adr/0004-sibling-setup-calls-and-bridge-owned-nesting.md`).

  `started_at` orders a process's open sibling spans: a parent run
  creating a durable child inside its own step opens a second step span
  on the same process, and the innermost one is the parent of what
  follows.
  """

  @enforce_keys [:span_ctx, :ctx, :started_at]
  defstruct [:span_ctx, :ctx, :started_at]

  @type t :: %__MODULE__{
          span_ctx: OpenTelemetry.span_ctx(),
          ctx: OpenTelemetry.Ctx.t(),
          started_at: integer()
        }
end
