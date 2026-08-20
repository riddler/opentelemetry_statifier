defmodule OpentelemetryStatifier do
  @moduledoc """
  OpenTelemetry instrumentation for the Statifier family of statechart
  packages.

  Attaches to the public `:telemetry` events the family emits - starting
  with statifier's `[:statifier, :session, ...]` contract
  (`Statifier.Session.Telemetry`) - and turns them into OpenTelemetry
  spans, span events, and span links. The library depends only on
  `opentelemetry_api`; hosts bring their own SDK and exporter.

  Nothing is implemented yet. The design this package implements lives in
  statifier-ex: `docs/opentelemetry.md` (span topology, context
  propagation, cardinality) and st-ADR-0062 (packaging and scope).
  """

  @doc """
  Placeholder until the bridge's setup API lands.

  ## Examples

      iex> OpentelemetryStatifier.setup()
      :ok

  """
  @spec setup() :: :ok
  def setup do
    :ok
  end
end
