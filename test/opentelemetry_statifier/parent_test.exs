defmodule OpentelemetryStatifier.ParentTest do
  # Global state twice over: `:telemetry`'s handler registry, and the
  # `:otel_simple_processor` exporter SpanCapture points at the test
  # process.
  use ExUnit.Case, async: false

  import OpentelemetryStatifier.SpanCapture

  require OpenTelemetry.Tracer

  alias OpentelemetryStatifier.{Parent, Persistence, SpanCapture, SpanTable}

  doctest OpentelemetryStatifier.Parent

  setup context do
    SpanCapture.start(context)

    table = :"parent_test_#{System.unique_integer([:positive])}"
    SpanTable.new_table(table)
    :ok = OpentelemetryStatifier.setup(table: table)

    %{table: table}
  end

  # A span the *host* owns, opened the way a foreign durable driver's own
  # step span is: from a context of its own, never this bridge's doing.
  defp host_span(name) do
    OpenTelemetry.Tracer.start_span(OpenTelemetry.Ctx.new(), name, %{})
  end

  defp emit_macrostep(session_id) do
    span_ref = make_ref()

    :telemetry.execute(
      [:statifier, :session, :macrostep, :start],
      %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
      %{session_id: session_id, trigger: :event, event_name: "go", span_ref: span_ref}
    )

    :telemetry.execute(
      [:statifier, :session, :macrostep, :stop],
      %{
        duration: 500,
        macrostep: 1,
        microsteps: 1,
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

  defp emit_step_start(run_id, span_ref) do
    :telemetry.execute(
      [:statifier_persistence, :run, :step, :start],
      %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
      %{run_id: run_id, entry: :step, span_ref: span_ref}
    )
  end

  defp emit_step_stop(run_id, span_ref) do
    :telemetry.execute(
      [:statifier_persistence, :run, :step, :stop],
      %{duration: 4242, monotonic_time: System.monotonic_time()},
      %{
        run_id: run_id,
        session_id: "session-1",
        content_hash: "abc123",
        entry: :step,
        outcome: :ok,
        status: :active,
        reason: nil,
        span_ref: span_ref
      }
    )
  end

  # Receives the captured span named `name`, whatever order the exporter
  # delivered the run's spans in.
  defp receive_span(name) do
    assert_receive {:span, captured} when span(captured, :name) == name, 1_000
    captured
  end

  describe "declaring an enclosing span" do
    # sabotage: `Parent.insert/3` writes no row (the SpanTable.put_parent_span
    # call is dropped) -> red (the macrostep roots its own trace again)
    test "the macrostep span nests under the declared span", %{table: table} do
      declared = host_span("my_app.workflow.step")

      assert {:ok, registration} = Parent.register(declared, table: table)
      emit_macrostep("session-1")
      assert :ok = Parent.unregister(registration)

      macrostep = receive_span("statifier.macrostep")

      assert span(macrostep, :parent_span_id) == OpenTelemetry.Span.span_id(declared)
      assert span(macrostep, :trace_id) == OpenTelemetry.Span.trace_id(declared)
    end

    # sabotage: `unregister/1` returns :ok without deleting the row -> red
    # (the macrostep after the withdrawal still nests)
    test "withdrawing it restores rooting, byte for byte", %{table: table} do
      declared = host_span("my_app.workflow.step")

      {:ok, registration} = Parent.register(declared, table: table)
      :ok = Parent.unregister(registration)

      emit_macrostep("session-1")

      assert span(receive_span("statifier.macrostep"), :parent_span_id) == :undefined
    end

    # sabotage: `fetch_enclosing_ctx/2` reads the process's ambient OTel
    # context when it finds no row -> red (the macrostep is captured into
    # the host's unrelated span)
    test "an ambient span nobody declared is still not a parent", %{table: _table} do
      OpenTelemetry.Tracer.with_span "my_app.unrelated_request" do
        emit_macrostep("session-1")
      end

      assert span(receive_span("statifier.macrostep"), :parent_span_id) == :undefined
    end

    # sabotage: `insert/3` keys the row on `self()` instead of the `:pid`
    # option -> red (the other process's macrostep roots)
    test "the :pid option declares the parent for another process", %{table: table} do
      declared = host_span("my_app.workflow.step")
      test_pid = self()

      driven =
        spawn(fn ->
          receive do
            :go ->
              emit_macrostep("session-1")
              send(test_pid, :emitted)
          end
        end)

      {:ok, _registration} = Parent.register(declared, pid: driven, table: table)
      send(driven, :go)
      assert_receive :emitted, 1_000

      assert span(receive_span("statifier.macrostep"), :parent_span_id) ==
               OpenTelemetry.Span.span_id(declared)
    end
  end

  describe "a registrant that dies" do
    # sabotage: `fetch_enclosing_ctx/2` drops its `Process.alive?(registrant)`
    # filter -> red (the macrostep nests under a span nobody will ever end)
    test "leaves the macrostep rooting its own trace", %{table: table} do
      declared = host_span("my_app.workflow.step")
      test_pid = self()

      registrant =
        spawn(fn ->
          {:ok, _registration} = Parent.register(declared, pid: test_pid, table: table)
          send(test_pid, :registered)
        end)

      assert_receive :registered, 1_000
      ref = Process.monitor(registrant)
      assert_receive {:DOWN, ^ref, :process, ^registrant, _reason}, 1_000

      emit_macrostep("session-1")

      assert span(receive_span("statifier.macrostep"), :parent_span_id) == :undefined
    end

    # sabotage: `sweep_parent_spans/1` ends the declared span before
    # deleting the row -> red (a span the host still owns is exported
    # early, and the host's own end_span is the second one)
    test "is swept without the bridge ending the span it did not open", %{table: table} do
      declared = host_span("my_app.workflow.step")
      test_pid = self()

      registrant =
        spawn(fn ->
          {:ok, _registration} = Parent.register(declared, pid: test_pid, table: table)
          send(test_pid, :registered)
        end)

      assert_receive :registered, 1_000
      ref = Process.monitor(registrant)
      assert_receive {:DOWN, ^ref, :process, ^registrant, _reason}, 1_000

      assert :ok = SpanTable.sweep(table)

      assert :ets.match_object(table, {{:parent_span, :_}, :_, :_}) == []
      refute_receive {:span, _swept}, 100

      OpenTelemetry.Span.end_span(declared)

      assert span(receive_span("my_app.workflow.step"), :span_id) ==
               OpenTelemetry.Span.span_id(declared)
    end
  end

  describe "composing with the family's own durable stepper" do
    setup %{table: table} do
      :ok = Persistence.setup(table: table)
      :ok
    end

    # sabotage: `fetch_enclosing_ctx/2` returns the declared row before the
    # sibling one instead of ordering both on their timestamps -> red (the
    # macrostep skips the step span and hangs off the host's span)
    test "the innermost of the two wins, and the step span nests in the declaration",
         %{table: table} do
      declared = host_span("my_app.workflow.step")
      step_ref = make_ref()

      {:ok, registration} = Parent.register(declared, table: table)
      emit_step_start("run-1", step_ref)
      emit_macrostep("session-1")
      emit_step_stop("run-1", step_ref)
      :ok = Parent.unregister(registration)

      step = receive_span("statifier_persistence.run.step")
      macrostep = receive_span("statifier.macrostep")

      assert span(step, :parent_span_id) == OpenTelemetry.Span.span_id(declared)
      assert span(macrostep, :parent_span_id) == span(step, :span_id)
      assert span(macrostep, :trace_id) == OpenTelemetry.Span.trace_id(declared)
    end

    # sabotage: the macrostep start clause goes back to
    # `OpenTelemetry.Ctx.new()` -> red (the sibling path loses its nesting)
    test "the sibling path is unchanged when nothing is ever declared", %{table: _table} do
      step_ref = make_ref()

      emit_step_start("run-2", step_ref)
      emit_macrostep("session-1")
      emit_step_stop("run-2", step_ref)

      step = receive_span("statifier_persistence.run.step")
      macrostep = receive_span("statifier.macrostep")

      assert span(step, :parent_span_id) == :undefined
      assert span(macrostep, :parent_span_id) == span(step, :span_id)
    end
  end

  describe "within/3" do
    # sabotage: `within/3` uses a plain call instead of `try/after` -> red
    # (the declaration outlives the raising block)
    test "withdraws the declaration even when the block raises", %{table: table} do
      declared = host_span("my_app.workflow.step")

      assert_raise RuntimeError, "boom", fn ->
        Parent.within(declared, fn -> raise "boom" end, table: table)
      end

      assert :ets.match_object(table, {{:parent_span, :_}, :_, :_}) == []

      emit_macrostep("session-1")
      assert span(receive_span("statifier.macrostep"), :parent_span_id) == :undefined
    end

    # sabotage: `within/3` returns `:ok` rather than the block's value ->
    # red
    test "nests what the block drives and returns its value", %{table: table} do
      declared = host_span("my_app.workflow.step")

      assert :stepped =
               Parent.within(
                 declared,
                 fn ->
                   emit_macrostep("session-1")
                   :stepped
                 end,
                 table: table
               )

      assert span(receive_span("statifier.macrostep"), :parent_span_id) ==
               OpenTelemetry.Span.span_id(declared)
    end

    # sabotage: `within/3` propagates the registration error instead of
    # running the block -> red (instrumentation decides whether the host's
    # work happens, which is exactly the failure mode this repo forbids)
    test "runs the block anyway when the declaration is refused" do
      assert :stepped = Parent.within(:undefined, fn -> :stepped end)
    end
  end

  describe "refusing a declaration" do
    # sabotage: `validate_span_ctx/1`'s catch-all clause is dropped -> red
    # (a FunctionClauseError instead of an ordinary error tuple)
    test "a span context that is not one is :invalid_span", %{table: table} do
      assert {:error, :invalid_span} = Parent.register(:undefined, table: table)
      assert {:error, :invalid_span} = Parent.register(nil, table: table)
      # Starts with the right tag and is still not a span context: the
      # record's arity is pinned, not just its first element.
      assert {:error, :invalid_span} = Parent.register({:span_ctx, 1, 2}, table: table)
    end

    # sabotage: `validate_span_ctx/1` stops checking for zero ids -> red
    # (OTel's invalid trace becomes a parent, and the tree is unrenderable)
    test "an all-zero span context is :invalid_span", %{table: table} do
      zeroed = :otel_tracer.from_remote_span(0, 0, 0)

      assert {:error, :invalid_span} = Parent.register(zeroed, table: table)
    end

    # sabotage: `validate_opts/1` accepts any key -> red (a typo'd option
    # is silently ignored and the declaration lands on the wrong process)
    test "an unknown option is refused, and nothing is written", %{table: table} do
      declared = host_span("my_app.workflow.step")

      assert {:error, {:unknown_options, [:nope]}} =
               Parent.register(declared, nope: true, table: table)

      assert :ets.match_object(table, {{:parent_span, :_}, :_, :_}) == []
    end

    # sabotage: `validate_table/1` skips the `:ets.whereis/1` check -> red
    # (an ArgumentError from ETS instead of an ordinary error tuple)
    test "a bridge that was never set up is :no_span_table" do
      declared = host_span("my_app.workflow.step")

      assert {:error, :no_span_table} = Parent.register(declared, table: :no_such_table)
    end

    # sabotage: `register/2` drops its `Process.alive?(pid)` check -> red
    # (a row is written for a process that can never emit anything)
    test "a dead :pid is :registrant_not_alive", %{table: table} do
      declared = host_span("my_app.workflow.step")
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}, 1_000

      assert {:error, :registrant_not_alive} = Parent.register(declared, pid: dead, table: table)
      assert :ets.match_object(table, {{:parent_span, :_}, :_, :_}) == []
    end
  end

  describe "unregister/1" do
    # sabotage: `unregister/1` drops its `:ets.whereis/1` guard -> red (an
    # ArgumentError when a host tears the table down before withdrawing)
    test "is idempotent, and survives a table that is already gone", %{table: table} do
      declared = host_span("my_app.workflow.step")

      {:ok, registration} = Parent.register(declared, table: table)

      assert :ok = Parent.unregister(registration)
      assert :ok = Parent.unregister(registration)

      :ets.delete(table)
      assert :ok = Parent.unregister(registration)
    end
  end
end
