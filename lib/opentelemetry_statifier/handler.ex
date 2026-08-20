defmodule OpentelemetryStatifier.Handler do
  @moduledoc """
  The `:telemetry` handler attached to every name
  `Statifier.Session.Telemetry.events/0` returns.

  There is deliberately no `try`/`rescue` here. `:telemetry` itself catches
  `error | exit | throw` from a raising handler and detaches it
  (`deps/telemetry/src/telemetry.erl:196-215`) - and because
  `OpentelemetryStatifier.setup/1` attaches one handler id per event name
  (rather than one `attach_many/4` id shared across all 27), a raise in one
  clause only costs that one event name, not the whole bridge, for the rest
  of the VM's life. The defensive posture this module actually needs is
  clause exhaustiveness - a final catch-all clause, matching
  `otel_telemetry.erl`'s own `handle_event(_, _, _, _) -> ok.` and ecto's
  `defp query_opts(_), do: %{}` - not rescue-to-default. Every clause here
  (the two macrostep clauses, plus later slices' clauses for the other 25
  names) must bind only the keys it needs in its head, so a malformed or
  unrecognised event falls through to the catch-all and drops the span
  rather than raising.
  """

  require OpenTelemetry.Tracer

  alias OpentelemetryStatifier.{Config, SpanEntry, SpanTable}

  @spec handle_event(:telemetry.event_name(), map(), map(), Config.t()) :: :ok

  # Opens a root span for a macrostep. `OpenTelemetry.Ctx.new/0` is an empty
  # context, never the process's ambient one - that is what makes each
  # macrostep the root of its own trace (the design note's "one trace per
  # macrostep"), and the span is deliberately never attached to the process
  # context, so the bridge cannot clobber a host's context inside the
  # session process. `span_ref` and `monotonic_time` are bound and guarded
  # in the head: a start missing either falls straight through to the
  # catch-all and is dropped rather than raising.
  def handle_event(
        [:statifier, :session, :macrostep, :start],
        %{monotonic_time: monotonic_time},
        %{session_id: session_id, trigger: trigger, span_ref: span_ref} = metadata,
        %Config{table: table}
      )
      when is_reference(span_ref) and is_integer(monotonic_time) do
    span_ctx =
      OpenTelemetry.Tracer.start_span(
        OpenTelemetry.Ctx.new(),
        "statifier.macrostep",
        %{start_time: monotonic_time, attributes: start_attributes(session_id, trigger, metadata)}
      )

    SpanTable.put_open_span(table, span_ref, %SpanEntry{
      session_id: session_id,
      span_ctx: span_ctx,
      trigger: trigger,
      started_at: monotonic_time
    })

    :ok
  end

  # Closes the macrostep span whose `span_ref` matches, pairing on `span_ref`
  # and never on `session_id` - st-ADR-0039 re-entry can have two spans open at
  # once for one session, and `span_ref` is the only exact correlation
  # mechanism the event contract offers. A stop with no matching open span
  # (`:error`) is contract-legal, not a bug (a crash mid-span leaves an
  # unmatched start), and is silently ignored here - ots-lt6's sweep is
  # where an orphan gets an error status.
  def handle_event(
        [:statifier, :session, :macrostep, :stop],
        %{monotonic_time: monotonic_time} = measurements,
        %{span_ref: span_ref} = metadata,
        %Config{table: table}
      )
      when is_reference(span_ref) and is_integer(monotonic_time) do
    case SpanTable.take_open_span(table, span_ref) do
      {:ok, %SpanEntry{span_ctx: span_ctx, session_id: session_id}} ->
        OpenTelemetry.Span.set_attributes(span_ctx, stop_attributes(measurements, metadata))
        ended = OpenTelemetry.Span.end_span(span_ctx, monotonic_time)
        SpanTable.put_last_span_ctx(table, session_id, ended)
        :ok

      :error ->
        :ok
    end
  end

  # The 25 events the macrostep clauses above do not name, and any malformed
  # measurements/metadata on any name (including the macrostep events
  # themselves), fall straight through here.
  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  @spec start_attributes(String.t(), atom(), map()) :: map()
  defp start_attributes(session_id, trigger, metadata) do
    %{
      "statifier.session_id" => session_id,
      "statifier.trigger" => Atom.to_string(trigger)
    }
    |> put_event_name(Map.get(metadata, :event_name))
  end

  @spec stop_attributes(map(), map()) :: map()
  defp stop_attributes(measurements, metadata) do
    %{}
    |> put_when(:has_key, "statifier.outcome", fetch_atom_as_string(metadata, :outcome))
    |> put_when(:has_key, "statifier.duration", Map.fetch(measurements, :duration))
    |> put_when(:has_key, "statifier.macrostep", Map.fetch(measurements, :macrostep))
    |> put_when(:has_key, "statifier.microsteps", Map.fetch(measurements, :microsteps))
    |> put_when(:has_key, "statifier.rounds", Map.fetch(measurements, :rounds))
    |> put_event_name(Map.get(metadata, :event_name))
    |> put_configuration(Map.get(metadata, :configuration))
  end

  # `event_name` is `nil` on `:initialize`/`:cancel`/`:resume` triggers - an
  # absent attribute is cleaner than a `"nil"` string, so it is omitted
  # entirely rather than set.
  @spec put_event_name(map(), String.t() | nil) :: map()
  defp put_event_name(attributes, nil), do: attributes

  defp put_event_name(attributes, event_name),
    do: Map.put(attributes, "statifier.event_name", event_name)

  @spec put_configuration(map(), MapSet.t(String.t()) | nil) :: map()
  defp put_configuration(attributes, nil), do: attributes

  defp put_configuration(attributes, %MapSet{} = configuration) do
    Map.put(
      attributes,
      "statifier.configuration",
      configuration |> MapSet.to_list() |> Enum.sort()
    )
  end

  # Every measurement/metadata read for the stop attributes is defensive: a
  # missing counter is omitted rather than raised via `Map.fetch!/2`.
  @spec put_when(map(), :has_key, String.t(), {:ok, term()} | :error) :: map()
  defp put_when(attributes, :has_key, _key, :error), do: attributes
  defp put_when(attributes, :has_key, key, {:ok, value}), do: Map.put(attributes, key, value)

  # `outcome` (`:quiescent | :done | :cancelled | :budget_exhausted`) is
  # identity metadata per the design note's uniform mapping - a
  # string attribute of the same name, like `trigger`.
  @spec fetch_atom_as_string(map(), atom()) :: {:ok, String.t()} | :error
  defp fetch_atom_as_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_atom(value) and not is_nil(value) -> {:ok, Atom.to_string(value)}
      _ -> :error
    end
  end
end
