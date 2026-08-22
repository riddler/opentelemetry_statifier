defmodule OpentelemetryStatifier.LifecycleTest do
  # Global state twice over: `:telemetry`'s handler registry, and the
  # `:otel_simple_processor` exporter SpanCapture points at the test
  # process.
  use ExUnit.Case, async: false

  import OpentelemetryStatifier.SpanCapture

  require Record

  alias OpentelemetryStatifier.SpanCapture
  alias OpentelemetryStatifier.SpanTable

  Record.defrecord(
    :status,
    Record.extract(:status, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
  )

  setup context do
    SpanCapture.start(context)

    table = :"lifecycle_test_#{System.unique_integer([:positive])}"
    SpanTable.new_table(table)
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

  defp emit_stop(session_id, span_ref) do
    :telemetry.execute(
      [:statifier, :session, :macrostep, :stop],
      %{
        duration: 500,
        macrostep: 3,
        microsteps: 7,
        rounds: 2,
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

  defp emit_terminate(session_id) do
    :telemetry.execute(
      [:statifier, :session, :terminate],
      %{macrostep: 3, microstep: 7, round: 2},
      %{session_id: session_id, reason: :normal, status: :running}
    )
  end

  defp emit_effect(session_id, kind) do
    :telemetry.execute(
      [:statifier, :session, :effect, kind],
      %{macrostep: 1, microstep: 2, round: 0},
      %{session_id: session_id}
    )
  end

  defp session_rows(table, session_id) do
    :ets.match_object(table, {:_, session_id, :_})
  end

  # Emits events from a short-lived process so the table's :session_pid
  # row points at a pid that is dead by the time the sweep runs. The
  # :DOWN message only arrives after the process has exited, so there is
  # no race against `Process.alive?/1` in the sweep.
  defp emit_from_dead_process(fun) do
    {pid, ref} = spawn_monitor(fun)

    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} -> :ok
    end
  end

  # Sorted: the SDK's internal event list is not insertion-ordered.
  defp span_event_names(captured) do
    captured
    |> span(:events)
    |> SpanCapture.events()
    |> Enum.map(&event(&1, :name))
    |> Enum.sort()
  end

  describe ":terminate cleanup" do
    # sabotage: Handler's :terminate clause dropped -> red (rows survive
    # and no error-status span is exported)
    test "ends a still-open span with error status and clears the session's rows",
         %{table: table} do
      emit_start("session-t1", make_ref())
      emit_terminate("session-t1")

      assert_receive {:span, captured}
      assert span(captured, :name) == "statifier.macrostep"

      assert span(captured, :status) ==
               status(
                 code: :error,
                 message: "statifier session terminated with the macrostep span still open"
               )

      assert session_rows(table, "session-t1") == []
    end

    # sabotage: delete_session/3's match_delete pattern narrowed to
    # {:span, :_} keys -> red (the last_span_ctx row survives below)
    test "after a clean stop removes the leftover rows without a second span",
         %{table: table} do
      span_ref = make_ref()
      emit_start("session-t2", span_ref)
      emit_stop("session-t2", span_ref)

      assert_receive {:span, _closed_normally}
      refute session_rows(table, "session-t2") == []

      emit_terminate("session-t2")

      refute_receive {:span, _}
      assert session_rows(table, "session-t2") == []
    end
  end

  describe "the orphan sweep" do
    # sabotage: sweep/1's `not Process.alive?(pid)` check inverted -> red
    # (the dead session's span is never ended, nothing arrives)
    test "ends a dead session's open span with error status and clears its rows",
         %{table: table} do
      emit_from_dead_process(fn -> emit_start("session-s1", make_ref()) end)

      :ok = SpanTable.sweep(table)

      assert_receive {:span, captured}
      assert span(captured, :name) == "statifier.macrostep"

      assert span(captured, :status) ==
               status(
                 code: :error,
                 message: "statifier session process died with the macrostep span still open"
               )

      assert session_rows(table, "session-s1") == []
    end

    # sabotage: put_session_pid/3 call removed from the handler's start
    # clause -> red (the sweep finds no :session_pid row and the live
    # assertion on rows below fails)
    test "leaves a live session's open span and rows untouched", %{table: table} do
      emit_start("session-s2", make_ref())

      :ok = SpanTable.sweep(table)

      refute_receive {:span, _}
      assert [_ | _] = :ets.match_object(table, {{:span, :_}, "session-s2", :_})
      assert [_ | _] = :ets.match_object(table, {{:session_pid, :_}, "session-s2", :_})
    end

    # sabotage: sweep/1 rewritten to only delete :span rows -> red (the
    # last_span_ctx row survives)
    test "clears a dead session's context rows even with no span open", %{table: table} do
      emit_from_dead_process(fn ->
        span_ref = make_ref()
        emit_start("session-s3", span_ref)
        emit_stop("session-s3", span_ref)
      end)

      assert_receive {:span, _closed_normally}
      refute session_rows(table, "session-s3") == []

      :ok = SpanTable.sweep(table)

      refute_receive {:span, _}
      assert session_rows(table, "session-s3") == []
    end

    # sabotage: handle_info/2's sweep(name) call removed -> red (the dead
    # session's error-status span never arrives)
    test "runs from the GenServer's timer message", %{table: table} do
      emit_from_dead_process(fn -> emit_start("session-s4", make_ref()) end)

      assert {:noreply, ^table} = SpanTable.handle_info(:sweep, table)

      assert_receive {:span, captured}
      assert status(code: :error, message: _message) = span(captured, :status)
      assert session_rows(table, "session-s4") == []
    end
  end

  describe "trace-off degradation" do
    # With `trace: false` the core emits no trace-family events at all, so
    # the bridge sees only lifecycle and effect events - this proves the
    # macrostep span and its effect span events survive that diet with no
    # bridge configuration.
    # sabotage: the handler's effect/trace span-event clause dropped its
    # :effect family -> red (the statifier.effect.send event is missing)
    test "macrostep spans keep effect span events when no trace events fire" do
      span_ref = make_ref()

      emit_start("session-d1", span_ref)
      emit_effect("session-d1", :send)
      emit_effect("session-d1", :log)
      emit_stop("session-d1", span_ref)

      assert_receive {:span, captured}
      refute_receive {:span, _}

      assert span(captured, :name) == "statifier.macrostep"
      assert span_event_names(captured) == ["statifier.effect.log", "statifier.effect.send"]
    end
  end
end
