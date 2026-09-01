defmodule OpentelemetryStatifier.Oban.Handler do
  @moduledoc """
  The `:telemetry` handler attached to every name
  `OpentelemetryStatifier.Oban.events/0` returns.

  Two clauses do the whole family, because the contract has exactly two
  seams and no pairs: a scheduling event lands on the macrostep span open
  in the emitting process, and a delivery event becomes its own span
  linked to the arming trace. The defensive posture is
  `OpentelemetryStatifier.Handler`'s - no `try`/`rescue`, exhaustive
  clauses, a catch-all that drops rather than raises inside a host's Oban
  worker.
  """

  alias OpentelemetryStatifier.{Attributes, Config, Sibling}

  @mapping Sibling.mapping("statifier_oban", :scope)

  @delivery [:fired, :discarded, :delivered, :failed]

  @spec handle_event(:telemetry.event_name(), map(), map(), Config.t()) :: :ok

  # The delivery seam: inside an Oban job, days after the macrostep that
  # armed it and usually on another node. Its own span, linked to the
  # arming trace through `caller_context` when the host stamped one -
  # never parented by it, which would hold that trace open for the length
  # of the delay.
  def handle_event(
        [:statifier_oban, seam, kind] = event,
        measurements,
        metadata,
        %Config{} = config
      )
      when seam in [:timer, :invoke] and kind in @delivery and is_map(measurements) and
             is_map(metadata) do
    Sibling.point(
      config,
      Sibling.name(event),
      :detached,
      attributes(measurements, metadata, config),
      Sibling.caller_context_links(Map.get(metadata, :caller_context))
    )
  end

  # The scheduling seam: synchronous, on the process that drove the
  # macrostep, so the macrostep span is open right there and the durable
  # consequence of the chart's decision belongs on it. `scope` is looked
  # up as the session id it corresponds to; a scope that is a host's
  # durable run id matches nothing, and the event becomes its own span.
  def handle_event(
        [:statifier_oban, seam, _kind] = event,
        measurements,
        metadata,
        %Config{} = config
      )
      when seam in [:timer, :invoke] and is_map(measurements) and is_map(metadata) do
    Sibling.point(
      config,
      Sibling.name(event),
      {:session, Map.get(metadata, :scope)},
      attributes(measurements, metadata, config),
      []
    )
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  @spec attributes(map(), map(), Config.t()) :: map()
  defp attributes(measurements, metadata, config) do
    Attributes.span_event_attributes(measurements, metadata, config, @mapping)
  end
end
