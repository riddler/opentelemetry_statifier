defmodule OpentelemetryStatifier.ParentEntry do
  @moduledoc """
  A *declared* enclosing span row held in
  `OpentelemetryStatifier.SpanTable`, written by
  `OpentelemetryStatifier.Parent.register/2` and removed by
  `OpentelemetryStatifier.Parent.unregister/1`.

  It is the foreign-driver half of ADR-0004 decision 4's nesting
  mechanism. A `%OpentelemetryStatifier.SiblingEntry{}` records a span
  *this bridge opened itself* from a sibling package's `:start` event; a
  `%ParentEntry{}` records a span **a host opened and handed in**, so a
  durable driver this package knows nothing about gets the same topology
  the family's own stepper gets - the macrostep span nesting inside the
  step span around it - without this bridge ever reading the process's
  ambient OTel context.

  The two row shapes stay separate because ownership differs, and
  ownership decides cleanup: the bridge ends a `SiblingEntry`'s span
  (on the matching `:stop`, or with an error status when the sweep finds
  its process dead), and it **never** ends a `ParentEntry`'s span. The
  host that opened it ends it.

  `pid` (element 2 of the row, the sibling-row convention) is the process
  whose spans nest under this one - the process that will emit the
  macrostep events, `self()` for a driver that steps the session
  synchronously in its own process.

  `registrant` is the process that called `register/2`, which is usually
  but not always the same one. It is the liveness key: a registration
  whose registrant has died is an abandoned declaration - nobody is left
  to call `unregister/1`, and nobody is left to end the declared span -
  so the spans that follow fall back to rooting their own traces rather
  than nesting under a span whose owner is gone.

  `ctx` is the OTel context with the declared span set as the current
  one, built from a fresh `OpenTelemetry.Ctx.new/0` and stored so a
  nested span starts from exactly this span without the bridge reading
  or writing the process's ambient context (ADR-0003 decision 8, as
  amended by ADR-0004 decision 4 and its 2026-09-02 Notes).

  `registered_at` orders a process's enclosing spans against the
  bridge's own open sibling spans: the most recently opened one is the
  innermost, and it is the parent of what follows.
  """

  @enforce_keys [:span_ctx, :ctx, :registrant, :registered_at]
  defstruct [:span_ctx, :ctx, :registrant, :registered_at]

  @type t :: %__MODULE__{
          span_ctx: OpenTelemetry.span_ctx(),
          ctx: OpenTelemetry.Ctx.t(),
          registrant: pid(),
          registered_at: integer()
        }
end
