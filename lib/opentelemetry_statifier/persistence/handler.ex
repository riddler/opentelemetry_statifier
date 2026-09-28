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

    * the step seam and the batch migration seam are pairs, and each
      becomes a span: `:start` opens it and exactly one of `:stop` or
      `:exception` closes it, the latter with an error status;
    * `[..., :adapter, :call]` and `[..., :execution, :lock]` are points that
      carry a `duration`, and become spans back-dated by it;
    * everything else is a point, and becomes a span event on the paired
      span open around it (the step or the batch) -
      `[..., :step, :reentered]` included, which has four segments but
      no `span_ref`, and so is a point rather than a half of the pair.

  Of the family's three list-valued keys, `:reentered`'s `opts` renders
  with `inspect/1` before the attribute rules see it, which would
  otherwise drop a list, and `:migrated`'s `dropped` becomes a sorted
  string-array attribute, as `configuration` does
  (`OpentelemetryStatifier.Persistence`'s moduledoc says why); the third,
  `:exception`'s `stacktrace`, is left to the rules and dropped as an
  attribute, and travels instead as the `exception.stacktrace` of the
  `exception` span event the close records.
  """

  alias OpentelemetryStatifier.{Attributes, Config, Sibling, SiblingEntry, SpanTable}

  @mapping Sibling.mapping("statifier_persistence", :session_id)

  # The family's two paired seams (ADR-0004's 2026-09-28 Amendment): the
  # step, and the batch migration `migrate_batch/3` brackets. Both pair on
  # `span_ref` and close the same way, so one set of clauses serves both.
  @paired_seams [:step, :migrate_batch]

  @spec handle_event(:telemetry.event_name(), map(), map(), Config.t()) :: :ok

  # A paired span. The step is the interval this package owns and nothing
  # else measures; the batch migration is the interval one
  # `migrate_batch/3` call takes, and every execution it moves lands on it
  # as a `migrated` span event, because that point fires on the calling
  # process inside it. `span_ref` pairs the halves - never
  # `execution_id`, which a parent creating a durable child inside its own
  # step has two of open at once, exactly as st-ADR-0039 re-entry does
  # upstream.
  def handle_event(
        [:statifier_persistence, :execution, seam, :start],
        %{monotonic_time: monotonic_time} = measurements,
        %{span_ref: span_ref} = metadata,
        %Config{} = config
      )
      when seam in @paired_seams and is_reference(span_ref) and is_integer(monotonic_time) do
    Sibling.open_span(
      config,
      Sibling.name([:statifier_persistence, :execution, seam]),
      span_ref,
      self(),
      monotonic_time,
      attributes(measurements, metadata, config)
    )
  end

  # The close carries the stop's measurements as attributes: `duration`,
  # and on the batch span one count per outcome of the mode, zeros
  # included, by the measurement rule every other number takes.
  def handle_event(
        [:statifier_persistence, :execution, seam, :stop],
        %{monotonic_time: monotonic_time} = measurements,
        %{span_ref: span_ref} = metadata,
        %Config{} = config
      )
      when seam in @paired_seams and is_reference(span_ref) and is_integer(monotonic_time) do
    Sibling.close_span(
      config,
      span_ref,
      monotonic_time,
      attributes(measurements, metadata, config)
    )
  end

  # A paired span's other close. `:exception` replaces `:stop` when the
  # drive or the batch raised, threw or exited, pairs on the same
  # `span_ref`, and ends the span with an error status. `reason` is
  # narrowed upstream to an atom, so the status message is bounded;
  # `stacktrace` is a list and the attribute rules drop it, so it travels
  # instead in the `exception` span event recorded on the span just
  # before it ends. The close does what `Sibling.close_span/5` does, but
  # here rather than through it, because the event has to land between
  # the take and the end.
  def handle_event(
        [:statifier_persistence, :execution, seam, :exception],
        %{monotonic_time: monotonic_time} = measurements,
        %{span_ref: span_ref} = metadata,
        %Config{table: table} = config
      )
      when seam in @paired_seams and is_reference(span_ref) and is_integer(monotonic_time) do
    case SpanTable.take_sibling_span(table, span_ref) do
      {:ok, %SiblingEntry{span_ctx: span_ctx}} ->
        OpenTelemetry.Span.set_attributes(span_ctx, attributes(measurements, metadata, config))
        OpenTelemetry.Span.add_event(span_ctx, "exception", exception_event_attributes(metadata))

        OpenTelemetry.Span.set_status(
          span_ctx,
          OpenTelemetry.status(:error, exception_message(metadata))
        )

        OpenTelemetry.Span.end_span(span_ctx, monotonic_time)
        :ok

      :error ->
        :ok
    end
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
    {dropped, metadata} = pop_dropped(metadata)

    measurements
    |> Attributes.span_event_attributes(render_lists(metadata), config, @mapping)
    |> put_dropped(dropped)
  end

  # `dropped` on `:migrated` is the state ids a migration dropped, each a
  # string by the upstream contract, so it becomes a sorted string-array
  # attribute - the rendering `configuration` takes, and a value a
  # backend can query per id. It is taken out of the metadata before the
  # attribute rules see it, which would drop a list, and put back under
  # the family's namespace afterwards. A `dropped` that is not a list of
  # strings stays in the metadata and meets the rules like any other
  # value: a malformed value costs one attribute, never the event. An
  # empty `dropped` is put back as `[]`, and the OpenTelemetry API refuses
  # an empty list, so a migration that drops no state exports no
  # `dropped` attribute.
  @dropped_attribute "statifier_persistence.dropped"

  @spec pop_dropped(map()) :: {[String.t()] | nil, map()}
  defp pop_dropped(%{dropped: dropped} = metadata) when is_list(dropped) do
    if Enum.all?(dropped, &is_binary/1),
      do: {Enum.sort(dropped), Map.delete(metadata, :dropped)},
      else: {nil, metadata}
  end

  defp pop_dropped(metadata), do: {nil, metadata}

  @spec put_dropped(map(), [String.t()] | nil) :: map()
  defp put_dropped(attributes, nil), do: attributes
  defp put_dropped(attributes, dropped), do: Map.put(attributes, @dropped_attribute, dropped)

  # `opts` on `:reentered` is list-valued. A list is a shape the
  # attribute rules drop, and it carries what a reader needs (the failed
  # `<send>`'s id), so it renders with `inspect/1`, the rendering tuples
  # already take. Any other value - `stacktrace` included - passes through
  # to the rules unchanged.
  @list_keys [:opts]

  @spec render_lists(map()) :: map()
  defp render_lists(metadata) do
    Enum.reduce(@list_keys, metadata, fn key, acc ->
      case acc do
        %{^key => value} when is_list(value) -> %{acc | key => inspect(value)}
        _other -> acc
      end
    end)
  end

  # The readable rendering of `reason`, `Elixir.` prefix stripped, while
  # the `reason` attribute and `exception.type` keep the module string.
  # The split is deliberate; `OpentelemetryStatifier.Persistence`'s
  # moduledoc says why.
  @spec exception_message(map()) :: String.t()
  defp exception_message(metadata) do
    "#{format_term(Map.get(metadata, :kind))}: #{format_term(Map.get(metadata, :reason))}"
  end

  # The OpenTelemetry exception semantic convention's two attributes, in
  # the shape `OpenTelemetry.Span.record_exception/4` gives them. That
  # call itself needs the exception struct, and the narrowed event
  # carries only its module, so the attributes are built here.
  # `exception.type` is the module for an `:error`, as `record_exception/4`
  # renders it, and `"<kind>:<reason>"` for a `:throw` or an `:exit`. That
  # is the shape `:otel_span.record_exception/5` gives one, not its bytes:
  # that call prints each term as Erlang does, so a module reason keeps
  # its `Elixir.` prefix inside single quotes, where `format_term/1` here
  # strips the prefix and adds no quotes. `exception.stacktrace` is
  # the narrowed frames formatted one per line; it is omitted when the
  # event carries no list of frames.
  @spec exception_event_attributes(map()) :: map()
  defp exception_event_attributes(metadata) do
    type = exception_type(Map.get(metadata, :kind), Map.get(metadata, :reason))

    case format_stacktrace(Map.get(metadata, :stacktrace)) do
      nil -> %{"exception.type" => type}
      stacktrace -> %{"exception.type" => type, "exception.stacktrace" => stacktrace}
    end
  end

  @spec exception_type(term(), term()) :: String.t()
  defp exception_type(:error, reason) when is_atom(reason) and not is_nil(reason),
    do: Atom.to_string(reason)

  defp exception_type(kind, reason), do: "#{format_term(kind)}:#{format_term(reason)}"

  # Every frame the narrowing keeps is `{module, function, arity,
  # location}`; one it could not read arrives as `:redacted` and renders
  # with `inspect/1` rather than reaching `Exception.format_stacktrace_entry/1`,
  # which would raise on it inside a host's durable step.
  @spec format_stacktrace(term()) :: String.t() | nil
  defp format_stacktrace(frames) when is_list(frames) and frames != [] do
    Enum.map_join(frames, fn frame -> "    " <> format_frame(frame) <> "\n" end)
  end

  defp format_stacktrace(_frames), do: nil

  @spec format_frame(term()) :: String.t()
  defp format_frame({module, function, arity, location} = frame)
       when is_atom(module) and is_atom(function) and is_integer(arity) and is_list(location) do
    Exception.format_stacktrace_entry(frame)
  end

  defp format_frame(frame), do: inspect(frame)

  @spec format_term(term()) :: String.t()
  defp format_term(term) when is_atom(term) and not is_nil(term) do
    case Atom.to_string(term) do
      "Elixir." <> module -> module
      name -> name
    end
  end

  defp format_term(term), do: inspect(term)
end
