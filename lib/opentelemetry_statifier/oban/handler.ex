defmodule OpentelemetryStatifier.Oban.Handler do
  @moduledoc """
  The `:telemetry` handler attached to every name
  `OpentelemetryStatifier.Oban.events/0` returns.

  Two clauses do the whole family, because the contract has no pairs and
  only two *shapes*: a scheduling event lands on the span open in the
  emitting process - the macrostep span when the session is stepping
  there, the durable driver's step span when a durable run id is all the
  event carries - and a delivery event becomes its own span linked to
  the arming trace. The fan-out seam adds names, not a third shape:
  `:fan_out` and `:child_started` fire inside Oban jobs carrying
  `caller_context` and so are delivery-shaped, while
  `:unstarted_cancelled` carries none, fires synchronously from the
  sweep, and is scheduling-shaped. The defensive posture is
  `OpentelemetryStatifier.Handler`'s - no `try`/`rescue`, exhaustive
  clauses, a catch-all that drops rather than raises inside a host's Oban
  worker.
  """

  alias OpentelemetryStatifier.{Attributes, Config, Sibling}

  @mapping Sibling.mapping("statifier_oban", :scope)

  # The kinds that fire inside an Oban job and carry `caller_context`.
  # `:fan_out` and `:child_started` are the fan-out seam's two: the
  # invocation's dispatch and one per chunk child, each a root linked to
  # the trace that planned it. `:unstarted_cancelled` is deliberately
  # absent - it has no `caller_context` to link with and it is emitted
  # synchronously by the sweep, so it belongs on the span open there.
  @delivery [:fired, :discarded, :delivered, :failed, :fan_out, :child_started]

  @spec handle_event(:telemetry.event_name(), map(), map(), Config.t()) :: :ok

  # The delivery seam and the fan-out seam's two job-borne events:
  # inside an Oban job, after the macrostep that armed or planned it and
  # usually on another node. Its own span, linked to that trace through
  # `caller_context` when the host stamped one - never parented by it,
  # which would hold the trace open for the length of the delay, or for
  # as long as a fan-out takes to start every child.
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
  # macrostep, so the span the durable consequence of the chart's
  # decision belongs on is open right there. `scope` is looked up as the
  # session id it corresponds to first; a scope that is a host's durable
  # run id matches no session, and the event falls back to whatever this
  # bridge has open in the emitting process - the durable driver's step
  # span. Only when neither is open does it become its own span.
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
      [{:session, Map.get(metadata, :scope)}, {:process, self()}],
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
