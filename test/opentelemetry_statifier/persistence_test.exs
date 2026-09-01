defmodule OpentelemetryStatifier.PersistenceTest do
  # Global state twice over: `:telemetry`'s handler registry, and the
  # `:otel_simple_processor` exporter SpanCapture points at the test
  # process.
  use ExUnit.Case, async: false

  import OpentelemetryStatifier.SpanCapture

  alias OpentelemetryStatifier.{Persistence, SpanCapture, SpanTable}
  alias OpentelemetryStatifier.Persistence.Handler

  setup context do
    SpanCapture.start(context)

    table = :"persistence_test_#{System.unique_integer([:positive])}"
    SpanTable.new_table(table)
    :ok = OpentelemetryStatifier.setup(table: table)
    :ok = Persistence.setup(table: table)

    %{table: table}
  end

  defp emit_step_start(run_id, span_ref, monotonic_time \\ System.monotonic_time()) do
    :telemetry.execute(
      [:statifier_persistence, :run, :step, :start],
      %{system_time: System.system_time(), monotonic_time: monotonic_time},
      %{run_id: run_id, entry: :step, span_ref: span_ref}
    )
  end

  defp emit_step_stop(run_id, span_ref, monotonic_time \\ System.monotonic_time()) do
    :telemetry.execute(
      [:statifier_persistence, :run, :step, :stop],
      %{duration: 4242, monotonic_time: monotonic_time},
      %{
        run_id: run_id,
        session_id: "session-p1",
        content_hash: "abc123",
        entry: :step,
        outcome: :ok,
        status: :active,
        reason: nil,
        span_ref: span_ref
      }
    )
  end

  defp emit_macrostep(session_id, span_ref) do
    :telemetry.execute(
      [:statifier, :session, :macrostep, :start],
      %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
      %{
        session_id: session_id,
        trigger: :event,
        event_name: "go",
        span_ref: span_ref,
        driver: :persistence
      }
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
        span_ref: span_ref,
        driver: :persistence
      }
    )
  end

  defp span_events(captured) do
    captured
    |> span(:events)
    |> SpanCapture.events()
    |> Enum.map(fn evt ->
      {event(evt, :name), SpanCapture.attributes(event(evt, :attributes))}
    end)
  end

  describe "attach discipline" do
    # sabotage: setup/1 attaches with :telemetry.attach_many/4 under one
    # shared id -> red (the per-event ids the assertion reads are absent)
    test "attaches one handler id per event name, ADR-0003 decision 2's discipline" do
      assert length(Persistence.events()) == 14

      for event <- Persistence.events() do
        assert [handler] = :telemetry.list_handlers(event)
        assert handler.id == {Persistence, event}
        assert handler.function == (&Handler.handle_event/4)
      end
    end

    # sabotage: setup/1 drops its `:ok = teardown()` line -> red (the
    # second attach is refused as already_exists, so the first call's
    # options stay in force with nothing to say so)
    test "setup/1 replaces the previous attachment rather than adding to it", %{table: table} do
      assert :ok = Persistence.setup(table: table)
      replacement = :"#{table}_replacement"
      assert :ok = Persistence.setup(table: replacement)

      for event <- Persistence.events() do
        assert [handler] = :telemetry.list_handlers(event)
        assert handler.config.table == replacement
      end

      :ok = Persistence.setup(table: table)
    end

    # sabotage: setup/1 attaches before validating opts -> red (handlers
    # exist for a config that was rejected)
    test "an invalid option attaches nothing" do
      :ok = Persistence.teardown()

      assert {:error, {:unknown_options, [:nope]}} = Persistence.setup(nope: true)
      assert :telemetry.list_handlers(hd(Persistence.events())) == []
    end

    # sabotage: teardown/0 detaches only the first event name -> red
    test "teardown/0 detaches every id this module owns" do
      :ok = Persistence.teardown()

      for event <- Persistence.events() do
        assert :telemetry.list_handlers(event) == []
      end
    end
  end

  describe "the step seam" do
    # sabotage: the step-start clause pairs on run_id instead of span_ref
    # -> red (take_sibling_span/2 misses and no span is ever ended)
    test "becomes one span carrying the run's identity" do
      span_ref = make_ref()

      emit_step_start("run-1", span_ref)
      emit_step_stop("run-1", span_ref)

      assert_receive {:span, step}
      assert span(step, :name) == "statifier_persistence.run.step"

      attributes = SpanCapture.attributes(span(step, :attributes))
      assert attributes["statifier_persistence.run_id"] == "run-1"
      assert attributes["statifier_persistence.entry"] == "step"
      assert attributes["statifier_persistence.outcome"] == "ok"
      assert attributes["statifier_persistence.status"] == "active"
      assert attributes["statifier_persistence.content_hash"] == "abc123"
      assert attributes["statifier_persistence.duration"] == 4242

      # The correlation key is the shared one, so a step joins the
      # macrostep spans inside it by attribute as well as by parenthood.
      assert attributes["statifier.session_id"] == "session-p1"
      refute Map.has_key?(attributes, "statifier_persistence.session_id")
    end

    # sabotage: the macrostep start clause goes back to
    # `OpenTelemetry.Ctx.new()` -> red (the macrostep is its own root
    # again and the step span is not its parent)
    test "the durable macrostep span nests inside it" do
      step_ref = make_ref()

      emit_step_start("run-2", step_ref)
      emit_macrostep("session-p1", make_ref())
      emit_step_stop("run-2", step_ref)

      assert_receive {:span, macrostep}
      assert_receive {:span, step}

      assert span(macrostep, :name) == "statifier.macrostep"
      assert span(macrostep, :parent_span_id) == span(step, :span_id)
      assert span(macrostep, :trace_id) == span(step, :trace_id)
    end

    # sabotage: interval_span/4 starts the span at `now` instead of
    # `now - duration` -> red (the span reports no duration)
    test "an adapter call becomes a span inside it, back-dated by its duration" do
      step_ref = make_ref()

      emit_step_start("run-3", step_ref)

      :telemetry.execute(
        [:statifier_persistence, :adapter, :call],
        %{duration: 1_000_000, system_time: System.system_time()},
        %{
          adapter: StatifierPersistence.Storage.Adapter.InMemory,
          callback: :fetch_position,
          outcome: :ok,
          reason: nil,
          run_id: "run-3",
          session_id: "session-p1",
          content_hash: "abc123"
        }
      )

      assert_receive {:span, adapter_call}
      emit_step_stop("run-3", step_ref)
      assert_receive {:span, step}

      assert span(adapter_call, :name) == "statifier_persistence.adapter.call"
      assert span(adapter_call, :parent_span_id) == span(step, :span_id)
      assert span(adapter_call, :end_time) - span(adapter_call, :start_time) == 1_000_000

      attributes = SpanCapture.attributes(span(adapter_call, :attributes))
      assert attributes["statifier_persistence.callback"] == "fetch_position"
      assert attributes["statifier_persistence.outcome"] == "ok"
      refute Map.has_key?(attributes, "statifier_persistence.system_time")
    end

    # sabotage: the catch-all point clause hosts on {:session, ...}
    # instead of {:process, self()} -> red (the event finds no step span
    # and becomes its own span rather than a span event)
    test "the lifecycle events land as span events on it" do
      step_ref = make_ref()

      emit_step_start("run-4", step_ref)

      :telemetry.execute(
        [:statifier_persistence, :identity, :refused],
        %{system_time: System.system_time()},
        %{
          run_id: "run-4",
          session_id: "session-p1",
          stage: :position,
          reason: :identity_mismatch,
          stored_content_hash: "stored",
          supplied_content_hash: "supplied"
        }
      )

      emit_step_stop("run-4", step_ref)

      assert_receive {:span, step}

      assert [{"statifier_persistence.identity.refused", attributes}] = span_events(step)
      assert attributes["statifier_persistence.stage"] == "position"
      assert attributes["statifier_persistence.reason"] == "identity_mismatch"
      assert attributes["statifier_persistence.stored_content_hash"] == "stored"
      assert attributes["statifier.session_id"] == "session-p1"
    end

    # sabotage: point/5 returns :ok instead of calling detached_span/4 on
    # a miss -> red (a run created outside any step is lost entirely)
    test "a point event with no step span open becomes its own span" do
      :telemetry.execute(
        [:statifier_persistence, :run, :created],
        %{system_time: System.system_time()},
        %{
          run_id: "run-5",
          session_id: "session-p1",
          content_hash: "abc123",
          child?: false,
          metadata?: true
        }
      )

      assert_receive {:span, created}
      assert span(created, :name) == "statifier_persistence.run.created"
      assert span(created, :parent_span_id) == :undefined

      attributes = SpanCapture.attributes(span(created, :attributes))
      assert attributes["statifier_persistence.metadata?"] == true
      assert attributes["statifier_persistence.child?"] == false
    end
  end

  describe "failure tolerance" do
    # sabotage: sweep_sibling_spans/1 is dropped from sweep/1 -> red (the
    # orphaned step span is never ended and never exported)
    test "a step span orphaned by a dead process is ended by the sweep", %{table: table} do
      parent = self()

      pid =
        spawn(fn ->
          emit_step_start("run-6", make_ref())
          send(parent, :emitted)
        end)

      assert_receive :emitted
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      :ok = SpanTable.sweep(table)

      assert_receive {:span, orphan}
      assert span(orphan, :name) == "statifier_persistence.run.step"
      assert {:status, :error, _message} = span(orphan, :status)
    end

    # sabotage: the point clause's head is widened from
    # `[:statifier_persistence, _phase, _kind]` to
    # `[:statifier_persistence | _rest]` -> red (a step start with no
    # `span_ref` becomes a point span for a pair that never opened,
    # instead of being dropped)
    test "a malformed event drops rather than raising" do
      :telemetry.execute(
        [:statifier_persistence, :run, :step, :start],
        %{},
        %{run_id: "run-7"}
      )

      refute_receive {:span, _span}, 50
      assert [_handler] = :telemetry.list_handlers([:statifier_persistence, :run, :step, :start])
    end
  end
end
