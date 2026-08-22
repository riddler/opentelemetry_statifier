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
  """

  @enforce_keys [:session_id, :span_ctx, :trigger, :started_at]
  defstruct [:session_id, :span_ctx, :trigger, :started_at]

  @type t :: %__MODULE__{
          session_id: String.t(),
          span_ctx: OpenTelemetry.span_ctx(),
          trigger: atom(),
          started_at: integer()
        }
end
