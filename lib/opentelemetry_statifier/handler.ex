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
  (the two macrostep clauses, the `:init` link-capture clause, and the
  span-event clauses for the effect/trace families plus
  `:interpret`/`:unroutable`/`:halt`) must bind only the keys it needs in
  its head, so a malformed or unrecognised event falls through to the
  catch-all and drops the span (or span event) rather than raising.
  """

  require OpenTelemetry.Tracer

  alias OpentelemetryStatifier.{Attributes, Config, SpanEntry, SpanTable}

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
        %{
          start_time: monotonic_time,
          attributes: start_attributes(session_id, trigger, metadata),
          links: macrostep_links(table, session_id, trigger)
        }
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

  # `:init` never becomes a span or a span event - it is handled only for
  # the invoke-parent link: when the new session was invoked by another
  # (`invoked_by: {pid, parent_session_id}`), and the parent's macrostep
  # span is open right now (invoke children start on the same node, inside
  # the invoking macrostep), that open span's context is parked under the
  # child's `session_id` for the child's own `:initialize` macrostep start
  # to turn into a link. A parent with no open span stores nothing - the
  # link degrades to absent, never to a guess.
  def handle_event(
        [:statifier, :session, :init],
        _measurements,
        %{session_id: session_id, invoked_by: {_pid, parent_session_id}},
        %Config{table: table}
      )
      when is_binary(session_id) and is_binary(parent_session_id) do
    case SpanTable.fetch_innermost_open_span(table, parent_session_id) do
      {:ok, %SpanEntry{span_ctx: parent_span_ctx}} ->
        SpanTable.put_invoke_parent(table, session_id, parent_span_ctx)

      :error ->
        :ok
    end
  end

  # The eleven `[:statifier, :session, :effect, kind]` and nine
  # `[:statifier, :session, :trace, kind]` events all become span events on
  # the session's innermost open macrostep span, named
  # `statifier.effect.<kind>` / `statifier.trace.<kind>` - the design
  # note's "span events, not child spans": they are points, not intervals,
  # and the `macrostep`/`microstep`/`round` measurements ride along as
  # attributes so the intra-macrostep timeline reconstructs from one span.
  def handle_event(
        [:statifier, :session, family, kind],
        measurements,
        %{session_id: session_id} = metadata,
        %Config{} = config
      )
      when family in [:effect, :trace] and is_atom(kind) and is_binary(session_id) and
             is_map(measurements) do
    add_span_event(config, session_id, "statifier.#{family}.#{kind}", measurements, metadata)
  end

  # `:interpret`, `:unroutable`, and `:halt` are the three remaining
  # intra-macrostep lifecycle events; same treatment, named
  # `statifier.<kind>`. (`:init` and `:terminate` are not span events -
  # neither fires inside a macrostep span.)
  def handle_event(
        [:statifier, :session, kind],
        measurements,
        %{session_id: session_id} = metadata,
        %Config{} = config
      )
      when kind in [:interpret, :unroutable, :halt] and is_binary(session_id) and
             is_map(measurements) do
    add_span_event(config, session_id, "statifier.#{kind}", measurements, metadata)
  end

  # `:terminate`, and any malformed measurements/metadata on any name
  # (including the clauses above), fall straight through here.
  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  # A span event with no open macrostep span to land on is dropped, not an
  # error: `:halt` can race a crash's cleanup, and an unmatched start is
  # already a published caveat of the event contract.
  @spec add_span_event(Config.t(), String.t(), String.t(), map(), map()) :: :ok
  defp add_span_event(%Config{table: table} = config, session_id, name, measurements, metadata) do
    case SpanTable.fetch_innermost_open_span(table, session_id) do
      {:ok, %SpanEntry{span_ctx: span_ctx}} ->
        OpenTelemetry.Span.add_event(
          span_ctx,
          name,
          Attributes.span_event_attributes(measurements, metadata, config)
        )

        :ok

      :error ->
        :ok
    end
  end

  # The two links the design note stitches macrostep traces with, both
  # attached at span start because OTel links cannot be added later:
  # every macrostep links to the same session's previous macrostep span
  # (so a backend walks a session's history across independently sampled
  # traces), and an `:initialize` macrostep additionally links to the
  # invoking parent's macrostep span parked by the `:init` clause above.
  # Links, not parent-child edges: neither neighbor contains this span's
  # duration.
  @spec macrostep_links(atom(), String.t(), atom()) :: [OpenTelemetry.link()]
  defp macrostep_links(table, session_id, trigger) do
    previous_macrostep_link(table, session_id) ++
      invoke_parent_link(table, session_id, trigger)
  end

  @spec previous_macrostep_link(atom(), String.t()) :: [OpenTelemetry.link()]
  defp previous_macrostep_link(table, session_id) do
    case SpanTable.fetch_last_span_ctx(table, session_id) do
      {:ok, span_ctx} -> [OpenTelemetry.link(span_ctx)]
      :error -> []
    end
  end

  @spec invoke_parent_link(atom(), String.t(), atom()) :: [OpenTelemetry.link()]
  defp invoke_parent_link(table, session_id, :initialize) do
    case SpanTable.take_invoke_parent(table, session_id) do
      {:ok, span_ctx} -> [OpenTelemetry.link(span_ctx)]
      :error -> []
    end
  end

  defp invoke_parent_link(_table, _session_id, _trigger), do: []

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
