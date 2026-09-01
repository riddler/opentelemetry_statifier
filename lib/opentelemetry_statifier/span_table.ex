defmodule OpentelemetryStatifier.SpanTable do
  @moduledoc """
  Owns the ETS table that holds open macrostep spans and, per session,
  the last span context ots-j82's links read.

  The table is created in `init/1` and otherwise untouched by this
  process - it is `:public` and `:named_table` so handlers read and write
  it directly from the session process that calls
  `OpentelemetryStatifier.Handler.handle_event/4`, with no message hop
  through this `GenServer`. Owning the table this way (rather than letting
  `setup/1` create it) means the table exists before any handler can fire,
  survives every session process, and gives ots-lt6's sweep timer a
  natural home - `opentelemetry_ecto`'s latent "owned by whoever called
  setup" bug does not reach this package.

  Row shapes, fixed here because ots-j82 and ots-lt6 both read them
  directly against the table name carried in `OpentelemetryStatifier.Config`:

      {{:span, span_ref},             session_id, %SpanEntry{}}
      {{:last_span_ctx, session_id},  session_id, span_ctx}
      {{:invoke_parent, session_id},  session_id, span_ctx}
      {{:session_pid, session_id},    session_id, pid}
      {{:sibling_span, span_ref},     pid,        %SiblingEntry{}}

  The `:sibling_span` row is the sibling families' half (ADR-0004): a
  `[:statifier_persistence, :run, :step, :start]` opens one keyed on the
  same `span_ref` convention, and it carries a **pid** in element 2 where
  the macrostep rows carry a `session_id`, because a step span is scoped
  to the process that drove it rather than to a logical session. That is
  what makes `fetch_innermost_sibling_span/2` a one-`match_object`
  lookup for "is one of this bridge's own spans open around me, in this
  process" - the question every nested sibling span and every durable
  macrostep span asks.

  The `:invoke_parent` row is written when a child session's `:init` event
  names an `invoked_by` parent whose macrostep span is open at that
  moment, and consumed (removed) by the child's own `:initialize`
  macrostep start, which turns it into a span link.

  The `:session_pid` row records the session process behind `session_id` -
  the handler runs inside the session process, so `self()` at event time
  is that pid. It exists for the sweep: `:terminate` does not fire on a
  brutal kill, so `sweep/1` walks these rows and, for every session whose
  process is no longer alive, ends any still-open macrostep spans with an
  error status and deletes all the session's rows - the design note's
  "sweeps entries whose sessions no longer exist rather than trusting the
  event alone". This `GenServer` runs the sweep on a timer; tests call
  `sweep/1` directly.

  `session_id` is duplicated into element 2 of every row shape so a
  sweeper can find every row for a session with one
  `:ets.match_object/2` or `:ets.match_delete/2`, without decoding either
  row's structured value.
  """

  use GenServer

  alias OpentelemetryStatifier.{SiblingEntry, SpanEntry}

  # One minute balances leak lifetime against wakeup cost: an orphaned row
  # is three tuples, so a longer leak costs almost nothing, and a sweep of
  # an empty table is one `match_object` call.
  @sweep_interval :timer.minutes(1)

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, __MODULE__, name: __MODULE__)
  end

  @impl GenServer
  def init(name) do
    new_table(name)
    schedule_sweep()
    {:ok, name}
  end

  @impl GenServer
  def handle_info(:sweep, name) do
    sweep(name)
    schedule_sweep()
    {:noreply, name}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end

  @doc """
  Creates (or returns, if it already exists under this process) a
  `:public`/`:named_table` ETS table under `name`. Tests call this
  directly with a unique name per test so they never depend on the
  application-started table.
  """
  @spec new_table(atom()) :: atom()
  def new_table(name) do
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, [:public, :named_table, :set])
      _tid -> name
    end
  end

  @doc """
  Stores an open span's `%SpanEntry{}` under its `span_ref`.
  """
  @spec put_open_span(atom(), reference(), SpanEntry.t()) :: :ok
  def put_open_span(table, span_ref, %SpanEntry{session_id: session_id} = entry) do
    :ets.insert(table, {{:span, span_ref}, session_id, entry})
    :ok
  end

  @doc """
  Looks up and removes the open span under `span_ref`, returning
  `{:ok, entry}` on a hit or `:error` on a miss - a `:stop` event with no
  matching `:start` is a contract-legal shape, not a bug, so this never
  raises.
  """
  @spec take_open_span(atom(), reference()) :: {:ok, SpanEntry.t()} | :error
  def take_open_span(table, span_ref) do
    case :ets.lookup(table, {:span, span_ref}) do
      [{{:span, ^span_ref}, _session_id, entry}] ->
        :ets.delete(table, {:span, span_ref})
        {:ok, entry}

      [] ->
        :error
    end
  end

  @doc """
  Fetches the innermost open span for `session_id` - the entry with the
  greatest `started_at` among the session's open rows, since ADR-0039
  re-entry can hold two spans open at once and an intra-macrostep event
  belongs to the most recently opened one. Returns `:error` when the
  session has no open span (an effect event racing a crash's cleanup is
  contract-legal, not a bug).
  """
  @spec fetch_innermost_open_span(atom(), String.t()) :: {:ok, SpanEntry.t()} | :error
  def fetch_innermost_open_span(table, session_id) do
    case :ets.match_object(table, {{:span, :_}, session_id, :_}) do
      [] ->
        :error

      rows ->
        {_key, _session_id, entry} =
          Enum.max_by(rows, fn {_key, _session_id, %SpanEntry{started_at: started_at}} ->
            started_at
          end)

        {:ok, entry}
    end
  end

  @doc """
  Stores an open sibling span's `%SiblingEntry{}` under its `span_ref`,
  keyed for lookup by the process that opened it.
  """
  @spec put_sibling_span(atom(), reference(), pid(), SiblingEntry.t()) :: :ok
  def put_sibling_span(table, span_ref, pid, %SiblingEntry{} = entry) do
    :ets.insert(table, {{:sibling_span, span_ref}, pid, entry})
    :ok
  end

  @doc """
  Looks up and removes the open sibling span under `span_ref`. Returns
  `:error` on a miss, which - as for `take_open_span/2` - is a
  contract-legal shape rather than a bug.
  """
  @spec take_sibling_span(atom(), reference()) :: {:ok, SiblingEntry.t()} | :error
  def take_sibling_span(table, span_ref) do
    case :ets.lookup(table, {:sibling_span, span_ref}) do
      [{{:sibling_span, ^span_ref}, _pid, entry}] ->
        :ets.delete(table, {:sibling_span, span_ref})
        {:ok, entry}

      [] ->
        :error
    end
  end

  @doc """
  Fetches the innermost sibling span open in `pid` - the entry with the
  greatest `started_at`, since a parent run creating a durable child
  inside its own step holds two step spans open on one process. Returns
  `:error` when the process has none, which is the ordinary case for a
  host that attached only the sibling setups it uses.
  """
  @spec fetch_innermost_sibling_span(atom(), pid()) :: {:ok, SiblingEntry.t()} | :error
  def fetch_innermost_sibling_span(table, pid) do
    case :ets.match_object(table, {{:sibling_span, :_}, pid, :_}) do
      [] ->
        :error

      rows ->
        {_key, _pid, entry} =
          Enum.max_by(rows, fn {_key, _pid, %SiblingEntry{started_at: started_at}} ->
            started_at
          end)

        {:ok, entry}
    end
  end

  @doc """
  Fetches the process recorded for `session_id` by `put_session_pid/3`,
  or `:error` for a session the bridge has not seen. The sibling
  handlers use it to check that a session's open macrostep span belongs
  to *this* process before landing a span event on it - a delivery-seam
  event on an Oban worker must never write onto a span another process
  has open for the same scope.
  """
  @spec fetch_session_pid(atom(), String.t()) :: {:ok, pid()} | :error
  def fetch_session_pid(table, session_id) do
    case :ets.lookup(table, {:session_pid, session_id}) do
      [{{:session_pid, ^session_id}, _session_id, pid}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Records the parent macrostep span context a child session's
  `:initialize` macrostep will link to, keyed by the child's `session_id`.
  """
  @spec put_invoke_parent(atom(), String.t(), OpenTelemetry.span_ctx()) :: :ok
  def put_invoke_parent(table, session_id, span_ctx) do
    :ets.insert(table, {{:invoke_parent, session_id}, session_id, span_ctx})
    :ok
  end

  @doc """
  Looks up and removes the invoke-parent span context stored for
  `session_id`, returning `{:ok, span_ctx}` on a hit or `:error` when no
  parent was recorded - a session that was not invoked by anyone.
  """
  @spec take_invoke_parent(atom(), String.t()) :: {:ok, OpenTelemetry.span_ctx()} | :error
  def take_invoke_parent(table, session_id) do
    case :ets.lookup(table, {:invoke_parent, session_id}) do
      [{{:invoke_parent, ^session_id}, _session_id, span_ctx}] ->
        :ets.delete(table, {:invoke_parent, session_id})
        {:ok, span_ctx}

      [] ->
        :error
    end
  end

  @doc """
  Records `span_ctx` as the last span context observed for `session_id`.
  """
  @spec put_last_span_ctx(atom(), String.t(), OpenTelemetry.span_ctx()) :: :ok
  def put_last_span_ctx(table, session_id, span_ctx) do
    :ets.insert(table, {{:last_span_ctx, session_id}, session_id, span_ctx})
    :ok
  end

  @doc """
  Fetches the last span context recorded for `session_id`, returning
  `{:ok, span_ctx}` on a hit or `:error` for an unknown session.
  """
  @spec fetch_last_span_ctx(atom(), String.t()) ::
          {:ok, OpenTelemetry.span_ctx()} | :error
  def fetch_last_span_ctx(table, session_id) do
    case :ets.lookup(table, {:last_span_ctx, session_id}) do
      [{{:last_span_ctx, ^session_id}, _session_id, span_ctx}] -> {:ok, span_ctx}
      [] -> :error
    end
  end

  @doc """
  Records `pid` as the session process behind `session_id`, for the
  sweep's liveness check. Idempotent - the table is a `:set`, so a
  session's row is written once per macrostep at no accumulating cost.
  """
  @spec put_session_pid(atom(), String.t(), pid()) :: :ok
  def put_session_pid(table, session_id, pid) do
    :ets.insert(table, {{:session_pid, session_id}, session_id, pid})
    :ok
  end

  @doc """
  Removes every row `session_id` owns, first ending any still-open
  macrostep spans with an error status carrying `orphan_message` - an
  orphan is reported, never silently dropped. Called by the handler's
  `:terminate` clause and by `sweep/1` for sessions whose process died
  without a `:terminate`.
  """
  @spec delete_session(atom(), String.t(), String.t()) :: :ok
  def delete_session(table, session_id, orphan_message) do
    table
    |> :ets.match_object({{:span, :_}, session_id, :_})
    |> Enum.each(fn {_key, _session_id, %SpanEntry{span_ctx: span_ctx}} ->
      OpenTelemetry.Span.set_status(span_ctx, OpenTelemetry.status(:error, orphan_message))
      OpenTelemetry.Span.end_span(span_ctx)
    end)

    :ets.match_delete(table, {:_, session_id, :_})
    :ok
  end

  @doc """
  Ends the orphans a brutal kill leaves behind: for every `:session_pid`
  row whose process is no longer alive, delegates to `delete_session/3`,
  and for every `:sibling_span` row whose process is no longer alive,
  ends that span with an error status and deletes the row. A live
  process's rows are never touched - an open span on a live process is
  just a step or a macrostep in flight, whatever its age.
  """
  @spec sweep(atom()) :: :ok
  def sweep(table) do
    table
    |> :ets.match_object({{:session_pid, :_}, :_, :_})
    |> Enum.each(fn {_key, session_id, pid} ->
      if not Process.alive?(pid) do
        delete_session(
          table,
          session_id,
          "statifier session process died with the macrostep span still open"
        )
      end
    end)

    sweep_sibling_spans(table)
  end

  # A sibling step span's two halves are emitted inside one synchronous
  # call, so the only way to orphan one is for that call's process to die
  # mid-step. There is no `:terminate`-shaped hook on that path - the
  # sibling contracts have none - so the liveness sweep is the whole
  # cleanup story for these rows.
  @spec sweep_sibling_spans(atom()) :: :ok
  defp sweep_sibling_spans(table) do
    table
    |> :ets.match_object({{:sibling_span, :_}, :_, :_})
    |> Enum.each(fn {key, pid, %SiblingEntry{span_ctx: span_ctx}} ->
      if not Process.alive?(pid) do
        OpenTelemetry.Span.set_status(
          span_ctx,
          OpenTelemetry.status(:error, "the process driving this step died with the span open")
        )

        OpenTelemetry.Span.end_span(span_ctx)
        :ets.delete(table, key)
      end
    end)

    :ok
  end
end
