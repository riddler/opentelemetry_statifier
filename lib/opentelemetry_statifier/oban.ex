defmodule OpentelemetryStatifier.Oban do
  @moduledoc """
  The bridge half for `statifier_oban`'s event family,
  `[:statifier_oban, ...]` - what happens between a chart's delayed send
  or invoke and the durable job row, frozen by that package's
  `docs/adr/0006-telemetry-events-for-the-durable-seams.md` and tabulated
  in its `docs/telemetry.md`.

  A **separate setup call**, per st-ADR-0062 and `ots-ADR-0002`
  decision 2:

      OpentelemetryStatifier.setup()
      OpentelemetryStatifier.Oban.setup()

  This module bridges `statifier_oban`'s eleven events and nothing else.
  Oban's own `[:oban, :job, ...]` spans are `opentelemetry_oban`'s to
  produce, and a host wanting both attaches both - the reason
  `statifier_oban` deliberately emits no duration, no attempt timing and
  no queue wait is that Oban already does.

  ## What it produces

  Every event in this family is a point - that contract has no
  `:start`/`:stop` pairs, because Oban owns every interval it could
  bracket - and the two seams land differently, exactly as the contract
  describes:

    * **The scheduling seam** (`:scheduled`, `:schedule_rejected`,
      `:cancelled`, `:enqueued`, `:enqueue_rejected` and the invoke
      `:cancelled`) fires synchronously on the process that drove the
      macrostep. When that macrostep's span is open in that same process,
      these become span events on it: the chart's decision and its
      durable consequence in one span.
    * **The delivery seam** (`:fired`, the two `:discarded`,
      `:delivered`, `:failed`) fires inside an Oban job, days later and
      usually on another node. Those become their own spans, **linked**
      to the trace that armed the timer through `caller_context` when the
      host stamped a W3C `traceparent` there. A link and never a parent:
      parenthood would hold the arming trace open for the length of the
      delay. With no `caller_context`, the span is simply unlinked - the
      ordinary detached case, correlated by `statifier.session_id`.

  `scope` is the correlation key here (it is either a live session's id
  or a host's durable run id, and this package cannot tell which), and it
  maps onto `statifier.session_id` - the rename happens here, once, where
  the mapping is visible, exactly as `statifier_oban`'s note asks.

  ## The event list

  The 11 names below are literal here rather than read from
  `StatifierOban.Telemetry.events/0`, for the reason
  `OpentelemetryStatifier.Persistence`'s moduledoc gives: bridging a
  sibling must not make that sibling - and Oban, and a database - a
  dependency of every host that wants statechart tracing.

  The list is not checked by hand either. `statifier_oban` is a
  `only: :test, runtime: false` dependency, and
  `test/opentelemetry_statifier/sibling_event_drift_test.exs` asserts this
  list against `StatifierOban.Telemetry.events/0` on every gate run.
  """

  alias OpentelemetryStatifier.Config
  alias OpentelemetryStatifier.Oban.Handler

  @events [
    [:statifier_oban, :timer, :scheduled],
    [:statifier_oban, :timer, :schedule_rejected],
    [:statifier_oban, :timer, :cancelled],
    [:statifier_oban, :timer, :fired],
    [:statifier_oban, :timer, :discarded],
    [:statifier_oban, :invoke, :enqueued],
    [:statifier_oban, :invoke, :enqueue_rejected],
    [:statifier_oban, :invoke, :cancelled],
    [:statifier_oban, :invoke, :delivered],
    [:statifier_oban, :invoke, :discarded],
    [:statifier_oban, :invoke, :failed]
  ]

  @doc """
  The event names this module attaches to - `statifier_oban`'s family, in
  full.

  ## Examples

      iex> length(OpentelemetryStatifier.Oban.events())
      11

  """
  @spec events() :: [:telemetry.event_name()]
  def events, do: @events

  @doc """
  Attaches this family with default options. Delegates to `setup/1`.

  ## Examples

      iex> OpentelemetryStatifier.Oban.setup()
      :ok

  """
  @spec setup() :: :ok | {:error, term()}
  def setup, do: setup([])

  @doc """
  Validates `opts` into a `OpentelemetryStatifier.Config.t()` and attaches
  this module's handler to every name `events/0` returns, one
  `:telemetry.attach/4` call per name under a per-event handler id
  (ADR-0003 decision 2). Idempotent, and independent of the other setups:
  it detaches and attaches nothing outside its own family.
  """
  @spec setup(keyword()) :: :ok | {:error, term()}
  def setup(opts) do
    with {:ok, config} <- Config.new(opts) do
      :ok = teardown()

      Enum.each(@events, fn event ->
        :telemetry.attach(handler_id(event), event, &Handler.handle_event/4, config)
      end)
    end
  end

  @doc """
  Detaches every handler id this module owns. Always returns `:ok`, even
  when nothing was attached.
  """
  @spec teardown() :: :ok
  def teardown do
    Enum.each(@events, &:telemetry.detach(handler_id(&1)))
  end

  defp handler_id(event), do: {__MODULE__, event}
end
