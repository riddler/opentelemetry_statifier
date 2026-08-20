defmodule OpentelemetryStatifier.HandlerTest do
  # Global state twice over: `:telemetry`'s handler registry, and the
  # `:otel_simple_processor` exporter SpanCapture points at the test
  # process.
  use ExUnit.Case, async: false

  import OpentelemetryStatifier.SpanCapture

  alias OpentelemetryStatifier.SpanCapture
  alias OpentelemetryStatifier.SpanTable

  setup context do
    SpanCapture.start(context)

    table = :"handler_test_#{System.unique_integer([:positive])}"
    SpanTable.new_table(table)
    :ok = OpentelemetryStatifier.setup(table: table)

    %{table: table}
  end

  defp emit_start(session_id, trigger, event_name, span_ref, monotonic_time) do
    :telemetry.execute(
      [:statifier, :session, :macrostep, :start],
      %{system_time: System.system_time(), monotonic_time: monotonic_time},
      %{session_id: session_id, trigger: trigger, event_name: event_name, span_ref: span_ref}
    )
  end

  defp emit_stop(
         session_id,
         trigger,
         outcome,
         event_name,
         configuration,
         span_ref,
         monotonic_time
       ) do
    :telemetry.execute(
      [:statifier, :session, :macrostep, :stop],
      %{
        duration: 500,
        macrostep: 3,
        microsteps: 7,
        rounds: 2,
        monotonic_time: monotonic_time
      },
      %{
        session_id: session_id,
        trigger: trigger,
        outcome: outcome,
        event_name: event_name,
        configuration: configuration,
        span_ref: span_ref
      }
    )
  end

  defp attrs(captured), do: captured |> span(:attributes) |> SpanCapture.attributes()

  # sabotage: start_attributes/3 dropped "statifier.trigger" from the map ->
  # red (the assertion on trigger below fails)
  test "a start/stop pair emits one statifier.macrostep span with the expected attributes" do
    span_ref = make_ref()
    configuration = MapSet.new(["b", "a", "c"])

    emit_start("session-1", :event, "go", span_ref, System.monotonic_time())

    emit_stop(
      "session-1",
      :event,
      :quiescent,
      "go",
      configuration,
      span_ref,
      System.monotonic_time()
    )

    assert_receive {:span, captured}
    refute_receive {:span, _}

    assert span(captured, :name) == "statifier.macrostep"

    assert attrs(captured) == %{
             "statifier.session_id" => "session-1",
             "statifier.trigger" => "event",
             "statifier.event_name" => "go",
             "statifier.outcome" => "quiescent",
             "statifier.duration" => 500,
             "statifier.macrostep" => 3,
             "statifier.microsteps" => 7,
             "statifier.rounds" => 2,
             "statifier.configuration" => ["a", "b", "c"]
           }
  end

  # sabotage: the start clause's `start_time:` is changed to `System.system_time()`
  # instead of the event's `monotonic_time` -> red
  test "start and end timestamps are exactly the monotonic_time values fed in" do
    span_ref = make_ref()
    start_time = System.monotonic_time()
    # ensure a measurable, distinct value from start_time
    end_time = start_time + 1_000_000

    emit_start("session-2", :event, "go", span_ref, start_time)
    emit_stop("session-2", :event, :quiescent, "go", MapSet.new(), span_ref, end_time)

    assert_receive {:span, captured}
    assert span(captured, :start_time) == start_time
    assert span(captured, :end_time) == end_time
  end

  # sabotage: the start clause starts the span from
  # `OpenTelemetry.Ctx.get_current()` instead of `OpenTelemetry.Ctx.new()` ->
  # red. An ambient span is set in the process below precisely so this
  # sabotage has something to leak from: with the fix, the macrostep span
  # is a root regardless of what the caller's process context holds; with
  # the mutation it would pick up the ambient span as its parent.
  test "each macrostep span is the root of its own trace" do
    require OpenTelemetry.Tracer

    ambient_ctx =
      OpenTelemetry.Tracer.start_span(OpenTelemetry.Ctx.new(), "ambient-caller-span", %{})

    OpenTelemetry.Tracer.set_current_span(ambient_ctx)

    span_ref_1 = make_ref()
    span_ref_2 = make_ref()

    emit_start("session-3", :event, "go", span_ref_1, System.monotonic_time())

    emit_stop(
      "session-3",
      :event,
      :quiescent,
      "go",
      MapSet.new(),
      span_ref_1,
      System.monotonic_time()
    )

    emit_start("session-3", :event, "go-again", span_ref_2, System.monotonic_time())

    emit_stop(
      "session-3",
      :event,
      :quiescent,
      "go-again",
      MapSet.new(),
      span_ref_2,
      System.monotonic_time()
    )

    assert_receive {:span, first}
    assert_receive {:span, second}

    assert span(first, :parent_span_id) == :undefined
    assert span(second, :parent_span_id) == :undefined
    assert span(first, :trace_id) != span(second, :trace_id)
  end

  # sabotage: pair on session_id -> red. The stop clause was changed to
  # `:ets.match_object(table, {{:span, :_}, session_id, :_})` and take the
  # oldest matching entry by `started_at`, instead of
  # `SpanTable.take_open_span(table, span_ref)`. With two spans open for
  # session-4, stop(B) then deterministically closes A (the older entry)
  # instead of B, so "the one closed first is B's, matched by its own
  # attributes" goes red.
  test "re-entry: start(A), start(B), stop(B), stop(A) emits two spans, closed in stop order" do
    span_ref_a = make_ref()
    span_ref_b = make_ref()

    emit_start("session-4", :event, "outer", span_ref_a, System.monotonic_time())
    emit_start("session-4", :internal, nil, span_ref_b, System.monotonic_time())

    emit_stop(
      "session-4",
      :internal,
      :quiescent,
      nil,
      MapSet.new(),
      span_ref_b,
      System.monotonic_time()
    )

    emit_stop(
      "session-4",
      :event,
      :done,
      "outer",
      MapSet.new(),
      span_ref_a,
      System.monotonic_time()
    )

    assert_receive {:span, first_closed}
    assert_receive {:span, second_closed}

    assert attrs(first_closed)["statifier.trigger"] == "internal"
    assert attrs(second_closed)["statifier.trigger"] == "event"

    refute Map.has_key?(attrs(first_closed), "statifier.event_name")
    assert attrs(second_closed)["statifier.event_name"] == "outer"

    assert span(first_closed, :parent_span_id) == :undefined
    assert span(second_closed, :parent_span_id) == :undefined
    assert span(first_closed, :span_id) != span(second_closed, :span_id)
    assert span(first_closed, :trace_id) != span(second_closed, :trace_id)
  end

  # sabotage: the start clause is changed to also call
  # `SpanTable.take_open_span/2` (as if every start also closed something) ->
  # red: the row would already be gone, so the later fetch_last_span_ctx/2
  # assertion in the paired test would not be affected, but this test's
  # "leaves a row in the table" assertion fails because the row disappears
  test "a start with no stop emits no span and leaves a row in the table", %{table: table} do
    span_ref = make_ref()
    emit_start("session-5", :event, "go", span_ref, System.monotonic_time())

    refute_receive {:span, _}

    assert {:ok, %OpentelemetryStatifier.SpanEntry{session_id: "session-5"}} =
             SpanTable.take_open_span(table, span_ref)
  end

  # sabotage: the stop clause's `:error` branch is changed to raise instead
  # of returning :ok -> red (the handler would be detached by :telemetry,
  # and the next assertion - handler still attached - would fail)
  test "a stop with an unknown span_ref emits nothing and does not raise" do
    emit_stop(
      "session-6",
      :event,
      :quiescent,
      "go",
      MapSet.new(),
      make_ref(),
      System.monotonic_time()
    )

    refute_receive {:span, _}

    assert {OpentelemetryStatifier, [:statifier, :session, :macrostep, :stop]} in handler_ids()
  end

  # sabotage: the start clause's guard drops `and is_reference(span_ref)` ->
  # red: a non-reference span_ref would then be accepted and stored as an
  # open-span row keyed on `:not_a_reference` (downstream code, and
  # ots-lt6's sweep, both assume a real reference key), so the "nothing was
  # stored" assertion below fails - a start alone never emits a span either
  # way, so `refute_receive` cannot distinguish this on its own.
  test "a start missing span_ref (or non-reference) emits nothing, and the handler stays attached",
       %{table: table} do
    :telemetry.execute(
      [:statifier, :session, :macrostep, :start],
      %{monotonic_time: System.monotonic_time()},
      %{session_id: "session-7", trigger: :event, event_name: "go", span_ref: :not_a_reference}
    )

    refute_receive {:span, _}
    assert :error = SpanTable.take_open_span(table, :not_a_reference)
    assert {OpentelemetryStatifier, [:statifier, :session, :macrostep, :start]} in handler_ids()
  end

  # sabotage: the stop clause is changed to skip
  # `SpanTable.put_last_span_ctx/3` -> red
  test "after a stop, SpanTable.fetch_last_span_ctx/2 returns the ended span ctx", %{table: table} do
    span_ref = make_ref()

    emit_start("session-8", :event, "go", span_ref, System.monotonic_time())

    emit_stop(
      "session-8",
      :event,
      :quiescent,
      "go",
      MapSet.new(),
      span_ref,
      System.monotonic_time()
    )

    assert_receive {:span, captured}
    assert {:ok, ended_ctx} = SpanTable.fetch_last_span_ctx(table, "session-8")
    assert OpenTelemetry.Span.span_id(ended_ctx) == span(captured, :span_id)
  end

  # sabotage: put_event_name/2 changed to always set the attribute, using
  # `to_string(nil)` for a nil event_name -> red
  test "an :initialize trigger with event_name: nil emits a span with no statifier.event_name attribute" do
    span_ref = make_ref()

    emit_start("session-9", :initialize, nil, span_ref, System.monotonic_time())

    emit_stop(
      "session-9",
      :initialize,
      :quiescent,
      nil,
      MapSet.new(),
      span_ref,
      System.monotonic_time()
    )

    assert_receive {:span, captured}
    refute Map.has_key?(attrs(captured), "statifier.event_name")
  end

  # sabotage: start_attributes/3 changed to omit "statifier.trigger" ->
  # red (every trigger assertion below fails)
  test "all five trigger values round-trip as strings" do
    for trigger <- [:initialize, :event, :cancel, :internal, :resume] do
      span_ref = make_ref()
      emit_start("session-10", trigger, nil, span_ref, System.monotonic_time())

      emit_stop(
        "session-10",
        trigger,
        :quiescent,
        nil,
        MapSet.new(),
        span_ref,
        System.monotonic_time()
      )

      assert_receive {:span, captured}
      assert attrs(captured)["statifier.trigger"] == Atom.to_string(trigger)
    end
  end

  defp handler_ids do
    :telemetry.list_handlers([:statifier])
    |> Enum.map(& &1.id)
  end
end
