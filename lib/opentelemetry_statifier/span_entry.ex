defmodule OpentelemetryStatifier.SpanEntry do
  @moduledoc """
  An open macrostep span row held in `OpentelemetryStatifier.SpanTable`
  between the macrostep `:start` event that creates it and the `:stop`
  event whose `span_ref` matches.

  `started_at` is the `monotonic_time` the span was opened with -
  `SpanTable.fetch_innermost_open_span/2` orders a session's open spans
  by it, and recomputing it from the span ctx is not possible through
  the API. (The sweep turned out not to need an age: it keys on session
  process liveness, via the table's `:session_pid` rows.)

  `macrostep` is the macrostep counter this span covers, and it is the
  one field here that is not known when the row is written. Statifier's
  `[:statifier, :session, :macrostep, :start]` event carries no
  `macrostep` measurement - the counter is authoritative only on the
  `:stop` half - so the field starts as `nil` and is filled in by
  `OpentelemetryStatifier.Handler` from the first intra-macrostep event
  that lands on the span, every one of which carries `macrostep` as a
  measurement (st-ADR-0040's event table). It exists so
  `OpentelemetryStatifier.SpanContext.lookup/2` can answer a keyed
  `(session_id, macrostep)` read; nothing in the span topology depends
  on it, and a span nobody ever emitted an effect or trace event inside
  keeps `nil` for its whole life.
  """

  @enforce_keys [:session_id, :span_ctx, :trigger, :started_at]
  defstruct [:session_id, :span_ctx, :trigger, :started_at, :macrostep]

  @type t :: %__MODULE__{
          session_id: String.t(),
          span_ctx: OpenTelemetry.span_ctx(),
          trigger: atom(),
          started_at: integer(),
          macrostep: non_neg_integer() | nil
        }
end
