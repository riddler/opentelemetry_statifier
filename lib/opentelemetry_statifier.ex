defmodule OpentelemetryStatifier do
  @moduledoc """
  OpenTelemetry instrumentation for the Statifier family of statechart
  packages.

  Attaches to the public `:telemetry` events the family emits - starting
  with statifier's `[:statifier, :session, ...]` contract
  (`Statifier.Session.Telemetry`) - and turns them into OpenTelemetry
  spans, span events, and span links. The library depends only on
  `opentelemetry_api`; hosts bring their own SDK and exporter.

  `setup/0`/`setup/1` attach `OpentelemetryStatifier.Handler.handle_event/4`
  to every name `Statifier.Session.Telemetry.events/0` returns, one
  `:telemetry.attach/4` call per name under a per-event handler id, so a
  raise in one event's handling never costs the others
  (`deps/telemetry/src/telemetry.erl:109-116`). `teardown/0` detaches all of
  them.

  Today the handler turns one event pair into spans: a macrostep `:start`
  opens a root span named `statifier.macrostep`, and the `:stop` whose
  `span_ref` matches closes it, carrying `statifier.session_id`,
  `statifier.trigger`, `statifier.outcome`, the macrostep's counters, and
  its resulting `statifier.configuration` as attributes
  (`OpentelemetryStatifier.Handler`, `OpentelemetryStatifier.SpanTable`).
  Span start times come from each event's own `monotonic_time`, so a
  macrostep span's wall time tracks the `statifier.duration` measurement
  closely - with one documented exception. Statifier emits the
  `:initialize` macrostep's `:start` from the session's `init/1` and its
  `:stop` from the following `handle_continue`, so that span opens after
  some of the work it covers, and reads materially shorter than
  `statifier.duration` reports. The skew is accepted rather than corrected;
  see the README and `docs/adr/0003-handler-attach-and-span-table-mechanism.md`.

  The other 25 events reach the handler and are silently ignored for now -
  the effect and trace events, span links, and the datamodel-values opt-in
  are later slices' work (see `docs/adr/0003-handler-attach-and-span-table-mechanism.md`).
  The design this package implements lives in statifier-ex:
  `docs/opentelemetry.md` (span topology, context propagation, cardinality)
  and st-ADR-0062 (packaging and scope).
  """

  alias OpentelemetryStatifier.{Config, Handler}
  alias Statifier.Session.Telemetry

  @doc """
  Attaches the bridge with default options. Delegates to `setup/1`.

  ## Examples

      iex> OpentelemetryStatifier.setup()
      :ok

  """
  @spec setup() :: :ok | {:error, term()}
  def setup, do: setup([])

  @doc """
  Validates `opts` into a `OpentelemetryStatifier.Config.t()` and attaches
  the bridge's handler to every name `Statifier.Session.Telemetry.events/0`
  returns.

  Idempotent: any ids this package already owns are detached first, so a
  second call - with the same or different options - replaces the first
  attachment rather than returning an "already exists" error.

  Returns `{:error, reason}` from `OpentelemetryStatifier.Config.new/1`
  without attaching anything when `opts` is invalid.
  """
  @spec setup(keyword()) :: :ok | {:error, term()}
  def setup(opts) do
    with {:ok, config} <- Config.new(opts) do
      :ok = teardown()

      Enum.each(Telemetry.events(), fn event ->
        :telemetry.attach(handler_id(event), event, &Handler.handle_event/4, config)
      end)
    end
  end

  @doc """
  Detaches every handler id this package owns. Always returns `:ok`, even
  when nothing was attached.
  """
  @spec teardown() :: :ok
  def teardown do
    Enum.each(Telemetry.events(), &:telemetry.detach(handler_id(&1)))
  end

  defp handler_id(event), do: {__MODULE__, event}
end
