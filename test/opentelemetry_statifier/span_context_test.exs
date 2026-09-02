defmodule OpentelemetryStatifier.SpanContextTest do
  # Global state twice over: `:telemetry`'s handler registry, and the
  # `:otel_simple_processor` exporter SpanCapture points at the test
  # process.
  use ExUnit.Case, async: false

  import OpentelemetryStatifier.SpanCapture

  alias OpentelemetryStatifier.SpanCapture
  alias OpentelemetryStatifier.SpanContext
  alias OpentelemetryStatifier.SpanEntry

  doctest OpentelemetryStatifier.SpanContext

  setup context do
    SpanCapture.start(context)

    table = :"span_context_test_#{System.unique_integer([:positive])}"
    OpentelemetryStatifier.SpanTable.new_table(table)
    :ok = OpentelemetryStatifier.setup(table: table)

    %{table: table}
  end

  defp emit_start(session_id, span_ref) do
    :telemetry.execute(
      [:statifier, :session, :macrostep, :start],
      %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
      %{session_id: session_id, trigger: :event, event_name: "go", span_ref: span_ref}
    )
  end

  defp emit_effect(session_id, macrostep) do
    :telemetry.execute(
      [:statifier, :session, :effect, :log],
      %{macrostep: macrostep, microstep: 1, round: 0},
      %{session_id: session_id, effect: :log, label: "hello"}
    )
  end

  defp emit_stop(session_id, span_ref, macrostep) do
    :telemetry.execute(
      [:statifier, :session, :macrostep, :stop],
      %{
        duration: 500,
        macrostep: macrostep,
        microsteps: 3,
        rounds: 1,
        monotonic_time: System.monotonic_time()
      },
      %{
        session_id: session_id,
        trigger: :event,
        outcome: :quiescent,
        event_name: "go",
        configuration: MapSet.new(),
        span_ref: span_ref
      }
    )
  end

  # sabotage: Handler.record_macrostep/4's is_integer clause dropped (so the
  # counter is never stamped onto the open row) -> red
  test "a hit while the macrostep span is open names that span's own ids", %{table: table} do
    span_ref = make_ref()
    emit_start("session-c1", span_ref)
    emit_effect("session-c1", 4)

    assert {:ok, %{trace_id: trace_id, span_id: span_id}} =
             SpanContext.lookup("session-c1", 4, table)

    # Closing the span exports it, which is what makes the ids checkable
    # against the span the backend actually receives rather than against
    # the table row they were read from.
    emit_stop("session-c1", span_ref, 4)
    assert_receive {:span, captured}

    assert trace_id == Base.encode16(<<span(captured, :trace_id)::128>>, case: :lower)
    assert span_id == Base.encode16(<<span(captured, :span_id)::64>>, case: :lower)
  end

  # sabotage: SpanContext.hex/2 drops its String.downcase/1 call -> red on
  # the lowercase-hex assertions
  test "the pair is W3C hex: 32 and 16 lowercase hex digits", %{table: table} do
    emit_start("session-c2", make_ref())
    emit_effect("session-c2", 0)

    assert {:ok, %{trace_id: trace_id, span_id: span_id}} =
             SpanContext.lookup("session-c2", 0, table)

    assert byte_size(trace_id) == 32
    assert byte_size(span_id) == 16
    assert trace_id =~ ~r/\A[0-9a-f]{32}\z/
    assert span_id =~ ~r/\A[0-9a-f]{16}\z/
  end

  # sabotage: SpanTable.fetch_open_span_ctx/3 drops its Enum.filter/2 on the
  # recorded counter (any open span for the session then answers) -> red
  test "a miss for an unknown session, an unrecorded counter, and a wrong counter",
       %{table: table} do
    span_ref = make_ref()

    assert :none = SpanContext.lookup("session-c3", 2, table)

    emit_start("session-c3", span_ref)
    # The span is open but no intra-macrostep event has carried a counter.
    assert :none = SpanContext.lookup("session-c3", 2, table)

    emit_effect("session-c3", 2)
    assert {:ok, _pair} = SpanContext.lookup("session-c3", 2, table)
    assert :none = SpanContext.lookup("session-c3", 3, table)
    assert :none = SpanContext.lookup("other-session", 2, table)
  end

  # sabotage: Handler's macrostep :stop clause changed to leave the row in
  # place (call fetch_innermost_open_span/2 instead of take_open_span/2) -> red
  test "a miss once the macrostep span has closed", %{table: table} do
    span_ref = make_ref()
    emit_start("session-c4", span_ref)
    emit_effect("session-c4", 1)

    assert {:ok, _pair} = SpanContext.lookup("session-c4", 1, table)

    emit_stop("session-c4", span_ref, 1)
    assert_receive {:span, _captured}

    assert :none = SpanContext.lookup("session-c4", 1, table)
  end

  # sabotage: SpanContext.lookup/3's `:ets.whereis/1` guard removed (the
  # match_object then raises ArgumentError instead of answering) -> red
  test "a table that does not exist is a miss, not a raise" do
    assert :none = SpanContext.lookup("session-c5", 1, :no_such_span_table)
  end

  # sabotage: SpanContext.lookup/3's catch-all clause removed -> red
  test "malformed arguments are a miss", %{table: table} do
    assert :none = SpanContext.lookup(:not_a_binary, 1, table)
    assert :none = SpanContext.lookup("session-c6", -1, table)
    assert :none = SpanContext.lookup("session-c6", "1", table)
    assert :none = SpanContext.lookup("session-c6", 1, nil)
  end

  # The all-zero ids are what a host that attached the bridge but started
  # no SDK gets: `:otel_tracer_noop.noop_span_ctx/0` is the very context
  # the API hands back on that path, confirmed against a real `mix run` in
  # this project dev environment. The suite always runs with an SDK, so
  # the no-op context is built explicitly here rather than provoked.
  #
  # sabotage: SpanContext.hex_pair/1's zero-id guard removed (it then
  # returns an all-zero pair, which is unusable in every backend) -> red
  test "a span context with the invalid all-zero ids is a miss", %{table: table} do
    OpentelemetryStatifier.SpanTable.put_open_span(table, make_ref(), %SpanEntry{
      session_id: "session-c8",
      span_ctx: :otel_tracer_noop.noop_span_ctx(),
      trigger: :event,
      started_at: System.monotonic_time(),
      macrostep: 1
    })

    assert %{trace_id: 0, span_id: 0} = noop_ids(table, "session-c8", 1)
    assert :none = SpanContext.lookup("session-c8", 1, table)
  end

  # Reads the ids straight off the stored context, so the test states what
  # it is actually asserting about rather than trusting the tracer to be
  # the no-op one.
  defp noop_ids(table, session_id, macrostep) do
    {:ok, span_ctx} =
      OpentelemetryStatifier.SpanTable.fetch_open_span_ctx(table, session_id, macrostep)

    %{
      trace_id: OpenTelemetry.Span.trace_id(span_ctx),
      span_id: OpenTelemetry.Span.span_id(span_ctx)
    }
  end

  # sabotage: SpanTable.fetch_innermost_open_row/2 changed to return the
  # oldest row instead of the newest -> red
  test "under re-entry the innermost open span answers for its own counter",
       %{table: table} do
    outer_ref = make_ref()
    inner_ref = make_ref()

    emit_start("session-c7", outer_ref)
    emit_effect("session-c7", 5)
    emit_start("session-c7", inner_ref)
    emit_effect("session-c7", 6)

    assert {:ok, outer} = SpanContext.lookup("session-c7", 5, table)
    assert {:ok, inner} = SpanContext.lookup("session-c7", 6, table)
    assert outer.span_id != inner.span_id
  end
end
