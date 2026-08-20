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

      {{:span, span_ref},            session_id, %SpanEntry{}}
      {{:last_span_ctx, session_id}, session_id, span_ctx}

  `session_id` is duplicated into element 2 of both row shapes so a
  sweeper can find every row for a session with one
  `:ets.match_object/2` or `:ets.match_delete/2`, without decoding either
  row's structured value.
  """

  use GenServer

  alias OpentelemetryStatifier.SpanEntry

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, __MODULE__, name: __MODULE__)
  end

  @impl GenServer
  def init(name) do
    new_table(name)
    {:ok, name}
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
end
