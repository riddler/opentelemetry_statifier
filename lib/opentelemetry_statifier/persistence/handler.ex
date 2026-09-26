defmodule OpentelemetryStatifier.Persistence.Handler do
  @moduledoc """
  The `:telemetry` handler attached to every name
  `OpentelemetryStatifier.Persistence.events/0` returns.

  Same defensive posture as `OpentelemetryStatifier.Handler`, for the
  same reason: no `try`/`rescue`, because `:telemetry` detaches a raising
  handler for the VM's lifetime and the per-event handler ids bound that
  loss to one event name. What this module owes instead is clause
  exhaustiveness - every clause binds only the keys it needs, and a
  malformed event falls through to the catch-all and drops a span rather
  than raising inside a host's durable step.

  Three shapes, decided by the contract rather than by this module
  (`statifier_persistence`'s `docs/telemetry.md`):

    * the step seam is a pair, and becomes a span: `:start` opens it and
      exactly one of `:stop` or `:exception` closes it, the latter with an
      error status;
    * `[..., :adapter, :call]` and `[..., :execution, :lock]` are points that
      carry a `duration`, and become spans back-dated by it;
    * everything else is a point, and becomes a span event on the step
      span open around it - `[..., :step, :reentered]` included, which
      has four segments but no `span_ref`, and so is a point rather than
      a half of the pair.

  Of the family's three list-valued keys, `:reentered`'s `opts` and
  `:migrated`'s `dropped` render with `inspect/1` before the attribute
  rules see them, which would otherwise drop a list
  (`OpentelemetryStatifier.Persistence`'s moduledoc says why); the third,
  `:exception`'s `stacktrace`, is left to the rules and dropped.
  """

  alias OpentelemetryStatifier.{Attributes, Config, Sibling}

  @mapping Sibling.mapping("statifier_persistence", :session_id)

  @spec handle_event(:telemetry.event_name(), map(), map(), Config.t()) :: :ok

  # The step span: the interval this package owns and nothing else
  # measures. `span_ref` pairs the halves - never `execution_id`, which a
  # parent creating a durable child inside its own step has two of open
  # at once, exactly as st-ADR-0039 re-entry does upstream.
  def handle_event(
        [:statifier_persistence, :execution, :step, :start],
        %{monotonic_time: monotonic_time} = measurements,
        %{span_ref: span_ref} = metadata,
        %Config{} = config
      )
      when is_reference(span_ref) and is_integer(monotonic_time) do
    Sibling.open_span(
      config,
      "statifier_persistence.execution.step",
      span_ref,
      self(),
      monotonic_time,
      attributes(measurements, metadata, config)
    )
  end

  def handle_event(
        [:statifier_persistence, :execution, :step, :stop],
        %{monotonic_time: monotonic_time} = measurements,
        %{span_ref: span_ref} = metadata,
        %Config{} = config
      )
      when is_reference(span_ref) and is_integer(monotonic_time) do
    Sibling.close_span(
      config,
      span_ref,
      monotonic_time,
      attributes(measurements, metadata, config)
    )
  end

  # The step span's other close. `:exception` replaces `:stop` when the
  # drive raised, threw or exited, pairs on the same `span_ref`, and ends
  # the span with an error status. `reason` is narrowed upstream to an
  # atom, so the status message is bounded; `stacktrace` is a list and
  # the attribute rules drop it.
  def handle_event(
        [:statifier_persistence, :execution, :step, :exception],
        %{monotonic_time: monotonic_time} = measurements,
        %{span_ref: span_ref} = metadata,
        %Config{} = config
      )
      when is_reference(span_ref) and is_integer(monotonic_time) do
    Sibling.close_span(
      config,
      span_ref,
      monotonic_time,
      attributes(measurements, metadata, config),
      OpenTelemetry.status(:error, exception_message(metadata))
    )
  end

  # The one four-segment point. A re-entry carries no `span_ref` - it
  # pairs with its step by arriving inside it, on the step's own process -
  # so it lands on the step span open in this process, and becomes its
  # own zero-duration span when there is none.
  def handle_event(
        [:statifier_persistence, :execution, :step, :reentered] = event,
        measurements,
        metadata,
        %Config{} = config
      )
      when is_map(measurements) and is_map(metadata) do
    Sibling.point(
      config,
      Sibling.name(event),
      {:process, self()},
      attributes(measurements, metadata, config),
      []
    )
  end

  # The two durational points. A lock wait and an adapter call are
  # intervals that have already closed by the time the event fires, so
  # the span is back-dated by `duration` - the contrib family's usual
  # shape, and the only one available for an event that reports an
  # interval rather than bracketing one.
  def handle_event(
        [:statifier_persistence, phase, kind] = event,
        %{duration: duration} = measurements,
        metadata,
        %Config{} = config
      )
      when is_integer(duration) and {phase, kind} in [{:adapter, :call}, {:execution, :lock}] do
    Sibling.interval_span(
      config,
      Sibling.name(event),
      duration,
      attributes(measurements, metadata, config)
    )
  end

  # Every other name in the family - all of them three-segment points.
  # They land on the step span open in this process (`:created`,
  # `:terminated`, `:discarded`, `:identity, :refused`,
  # `:effect, :failed`, `:turns_exhausted` and the four child-seam events
  # are all emitted inside `serialized/4`) and become their own
  # zero-duration span when there is none. Matching three segments rather
  # than the whole family is deliberate: a *malformed* step event - four
  # segments, missing its `span_ref` - must fall through to the catch-all
  # and be dropped, not become a point span for a pair that never opened.
  def handle_event(
        [:statifier_persistence, _phase, _kind] = event,
        measurements,
        metadata,
        %Config{} = config
      )
      when is_map(measurements) and is_map(metadata) do
    Sibling.point(
      config,
      Sibling.name(event),
      {:process, self()},
      attributes(measurements, metadata, config),
      []
    )
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  @spec attributes(map(), map(), Config.t()) :: map()
  defp attributes(measurements, metadata, config) do
    Attributes.span_event_attributes(measurements, render_lists(metadata), config, @mapping)
  end

  # `opts` on `:reentered` and `dropped` on `:migrated` are list-valued.
  # A list is a shape the attribute rules drop, and each of these carries
  # what a reader needs (the failed `<send>`'s id, the state ids a
  # migration dropped), so each renders with `inspect/1`, the rendering
  # tuples already take. Any other value - `stacktrace` included - passes
  # through to the rules unchanged.
  @list_keys [:opts, :dropped]

  @spec render_lists(map()) :: map()
  defp render_lists(metadata) do
    Enum.reduce(@list_keys, metadata, fn key, acc ->
      case acc do
        %{^key => value} when is_list(value) -> %{acc | key => inspect(value)}
        _other -> acc
      end
    end)
  end

  @spec exception_message(map()) :: String.t()
  defp exception_message(metadata) do
    "#{format_term(Map.get(metadata, :kind))}: #{format_term(Map.get(metadata, :reason))}"
  end

  @spec format_term(term()) :: String.t()
  defp format_term(term) when is_atom(term) and not is_nil(term) do
    case Atom.to_string(term) do
      "Elixir." <> module -> module
      name -> name
    end
  end

  defp format_term(term), do: inspect(term)
end
