defmodule OpentelemetryStatifier.SpanEntry do
  @moduledoc """
  An open macrostep span row held in `OpentelemetryStatifier.SpanTable`
  between the macrostep `:start` event that creates it and the `:stop`
  event whose `span_ref` matches.

  `started_at` is the `monotonic_time` the span was opened with -
  ots-lt6's sweep needs an age, and recomputing it from the span ctx is
  not possible through the API.
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
