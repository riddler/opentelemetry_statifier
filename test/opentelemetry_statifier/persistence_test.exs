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

  defp emit_step_start(execution_id, span_ref, monotonic_time \\ System.monotonic_time()) do
    :telemetry.execute(
      [:statifier_persistence, :execution, :step, :start],
      %{system_time: System.system_time(), monotonic_time: monotonic_time},
      %{execution_id: execution_id, entry: :step, span_ref: span_ref}
    )
  end

  defp emit_step_stop(execution_id, span_ref, monotonic_time \\ System.monotonic_time()) do
    :telemetry.execute(
      [:statifier_persistence, :execution, :step, :stop],
      %{duration: 4242, monotonic_time: monotonic_time},
      %{
        execution_id: execution_id,
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
      assert length(Persistence.events()) == 20

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
    # sabotage: the step-start clause pairs on execution_id instead of span_ref
    # -> red (take_sibling_span/2 misses and no span is ever ended)
    test "becomes one span carrying the execution's identity" do
      span_ref = make_ref()

      emit_step_start("exec-1", span_ref)
      emit_step_stop("exec-1", span_ref)

      assert_receive {:span, step}
      assert span(step, :name) == "statifier_persistence.execution.step"

      attributes = SpanCapture.attributes(span(step, :attributes))
      assert attributes["statifier_persistence.execution_id"] == "exec-1"
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

      emit_step_start("exec-2", step_ref)
      emit_macrostep("session-p1", make_ref())
      emit_step_stop("exec-2", step_ref)

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

      emit_step_start("exec-3", step_ref)

      :telemetry.execute(
        [:statifier_persistence, :adapter, :call],
        %{duration: 1_000_000, system_time: System.system_time()},
        %{
          adapter: StatifierPersistence.Storage.Adapter.InMemory,
          callback: :fetch_position,
          outcome: :ok,
          reason: nil,
          execution_id: "exec-3",
          session_id: "session-p1",
          content_hash: "abc123"
        }
      )

      assert_receive {:span, adapter_call}
      emit_step_stop("exec-3", step_ref)
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

      emit_step_start("exec-4", step_ref)

      :telemetry.execute(
        [:statifier_persistence, :identity, :refused],
        %{system_time: System.system_time()},
        %{
          execution_id: "exec-4",
          session_id: "session-p1",
          stage: :position,
          reason: :identity_mismatch,
          stored_content_hash: "stored",
          supplied_content_hash: "supplied"
        }
      )

      emit_step_stop("exec-4", step_ref)

      assert_receive {:span, step}

      assert [{"statifier_persistence.identity.refused", attributes}] = span_events(step)
      assert attributes["statifier_persistence.stage"] == "position"
      assert attributes["statifier_persistence.reason"] == "identity_mismatch"
      assert attributes["statifier_persistence.stored_content_hash"] == "stored"
      assert attributes["statifier.session_id"] == "session-p1"
    end

    # sabotage: point/5 returns :ok instead of calling detached_span/4 on
    # a miss -> red (an execution created outside any step is lost entirely)
    test "a point event with no step span open becomes its own span" do
      :telemetry.execute(
        [:statifier_persistence, :execution, :created],
        %{system_time: System.system_time()},
        %{
          execution_id: "exec-5",
          session_id: "session-p1",
          content_hash: "abc123",
          child?: false,
          metadata?: true
        }
      )

      assert_receive {:span, created}
      assert span(created, :name) == "statifier_persistence.execution.created"
      assert span(created, :parent_span_id) == :undefined

      attributes = SpanCapture.attributes(span(created, :attributes))
      assert attributes["statifier_persistence.metadata?"] == true
      assert attributes["statifier_persistence.child?"] == false
    end
  end

  describe "the events statifier_persistence 0.19 added" do
    # sabotage: the step-exception clause is deleted from the Handler ->
    # red (the event falls to the catch-all, the span stays open and
    # nothing is exported)
    test "a step exception closes the step span with an error status" do
      span_ref = make_ref()

      emit_step_start("exec-8", span_ref)

      :telemetry.execute(
        [:statifier_persistence, :execution, :step, :exception],
        %{duration: 777, monotonic_time: System.monotonic_time()},
        %{
          execution_id: "exec-8",
          entry: :step,
          span_ref: span_ref,
          kind: :error,
          reason: RuntimeError,
          stacktrace: [{Some.Executor, :run, 2, [file: ~c"lib/some.ex", line: 7]}]
        }
      )

      assert_receive {:span, step}
      assert span(step, :name) == "statifier_persistence.execution.step"

      # sabotage: close_span/5 ignores its status argument -> red (the
      # span closes unset, and a failed drive reads as a clean one)
      assert {:status, :error, message} = span(step, :status)
      assert message == "error: RuntimeError"

      attributes = SpanCapture.attributes(span(step, :attributes))
      assert attributes["statifier_persistence.kind"] == "error"
      assert attributes["statifier_persistence.reason"] == "Elixir.RuntimeError"
      assert attributes["statifier_persistence.duration"] == 777
      refute Map.has_key?(attributes, "statifier_persistence.stacktrace")
    end

    # sabotage: the step-exception clause closes the process's innermost
    # open step span instead of the one under its span_ref -> red (the
    # open span is closed with an error status by an exception it never
    # paired with)
    test "a step exception pairs on span_ref and closes nothing else" do
      span_ref = make_ref()

      emit_step_start("exec-9", span_ref)

      :telemetry.execute(
        [:statifier_persistence, :execution, :step, :exception],
        %{duration: 1, monotonic_time: System.monotonic_time()},
        %{execution_id: "exec-9", entry: :step, span_ref: make_ref(), kind: :throw, reason: :x}
      )

      refute_receive {:span, _span}, 50

      emit_step_stop("exec-9", span_ref)

      assert_receive {:span, step}
      assert span(step, :status) == :undefined
    end

    # sabotage: the reentered clause is deleted from the Handler -> red
    # (the event falls to the catch-all and the step span carries no
    # span event)
    test "a step re-entry lands as a span event on the open step span" do
      span_ref = make_ref()

      emit_step_start("exec-10", span_ref)

      :telemetry.execute(
        [:statifier_persistence, :execution, :step, :reentered],
        %{system_time: System.system_time()},
        %{
          execution_id: "exec-10",
          session_id: "session-p1",
          content_hash: "abc123",
          name: "error.communication",
          origin: {:transition, 2},
          opts: [sendid: "s1"]
        }
      )

      emit_step_stop("exec-10", span_ref)

      assert_receive {:span, step}

      assert [{"statifier_persistence.execution.step.reentered", attributes}] = span_events(step)
      assert attributes["statifier_persistence.name"] == "error.communication"
      assert attributes["statifier_persistence.origin"] == "{:transition, 2}"
      # sabotage: render_lists/2 is skipped for :opts -> red (a keyword
      # list is dropped by the attribute rules and the sendid is lost)
      assert attributes["statifier_persistence.opts"] == ~s([sendid: "s1"])
      assert attributes["statifier.session_id"] == "session-p1"
      refute Map.has_key?(attributes, "statifier_persistence.system_time")
    end

    # sabotage: the reentered clause hosts on :detached -> red (the
    # re-entry becomes its own span even with the step span open, and
    # this test's twin above sees no span event)
    test "a step re-entry with no step span open becomes its own span" do
      :telemetry.execute(
        [:statifier_persistence, :execution, :step, :reentered],
        %{system_time: System.system_time()},
        %{
          execution_id: "exec-11",
          session_id: nil,
          content_hash: "abc123",
          name: "error.communication",
          origin: {:invoke, 0, 1},
          opts: []
        }
      )

      assert_receive {:span, reentered}
      assert span(reentered, :name) == "statifier_persistence.execution.step.reentered"
      assert span(reentered, :parent_span_id) == :undefined

      attributes = SpanCapture.attributes(span(reentered, :attributes))
      assert attributes["statifier_persistence.opts"] == "[]"
      refute Map.has_key?(attributes, "statifier.session_id")
    end

    # sabotage: [:statifier_persistence, :execution, :migrated] deleted
    # from Persistence's @events -> red (nothing is attached to the name)
    test "a migration becomes a point carrying both content hashes" do
      :telemetry.execute(
        [:statifier_persistence, :execution, :migrated],
        %{system_time: System.system_time()},
        %{
          execution_id: "exec-12",
          from_content_hash: "old",
          to_content_hash: "new",
          dropped: ["gone_a", "gone_b"]
        }
      )

      assert_receive {:span, migrated}
      assert span(migrated, :name) == "statifier_persistence.execution.migrated"

      attributes = SpanCapture.attributes(span(migrated, :attributes))
      assert attributes["statifier_persistence.execution_id"] == "exec-12"
      assert attributes["statifier_persistence.from_content_hash"] == "old"
      assert attributes["statifier_persistence.to_content_hash"] == "new"
      # sabotage: render_lists/2 is skipped for :dropped -> red
      assert attributes["statifier_persistence.dropped"] == ~s(["gone_a", "gone_b"])
    end

    # sabotage: [:statifier_persistence, :execution, :unparked] deleted
    # from Persistence's @events -> red (nothing is attached to the name)
    test "an unpark becomes a point carrying the chart it goes on under" do
      :telemetry.execute(
        [:statifier_persistence, :execution, :unparked],
        %{system_time: System.system_time()},
        %{execution_id: "exec-13", content_hash: "abc123"}
      )

      assert_receive {:span, unparked}
      assert span(unparked, :name) == "statifier_persistence.execution.unparked"

      attributes = SpanCapture.attributes(span(unparked, :attributes))
      assert attributes["statifier_persistence.execution_id"] == "exec-13"
      assert attributes["statifier_persistence.content_hash"] == "abc123"
    end

    # sabotage: the step-stop clause maps attributes through an explicit
    # key list that omits :selection -> red
    test "the step stop's selection key rides as an attribute" do
      span_ref = make_ref()

      emit_step_start("exec-14", span_ref)

      :telemetry.execute(
        [:statifier_persistence, :execution, :step, :stop],
        %{duration: 10, monotonic_time: System.monotonic_time()},
        %{
          execution_id: "exec-14",
          session_id: "session-p1",
          content_hash: "abc123",
          entry: :step,
          outcome: :ok,
          status: :active,
          reason: nil,
          span_ref: span_ref,
          invoke_id: nil,
          child_count: nil,
          selection: :none
        }
      )

      assert_receive {:span, step}
      attributes = SpanCapture.attributes(span(step, :attributes))
      assert attributes["statifier_persistence.selection"] == "none"
      assert span(step, :status) == :undefined
    end
  end

  describe "failure tolerance" do
    # sabotage: sweep_sibling_spans/1 is dropped from sweep/1 -> red (the
    # orphaned step span is never ended and never exported)
    test "a step span orphaned by a dead process is ended by the sweep", %{table: table} do
      parent = self()

      pid =
        spawn(fn ->
          emit_step_start("exec-6", make_ref())
          send(parent, :emitted)
        end)

      assert_receive :emitted
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      :ok = SpanTable.sweep(table)

      assert_receive {:span, orphan}
      assert span(orphan, :name) == "statifier_persistence.execution.step"
      assert {:status, :error, _message} = span(orphan, :status)
    end

    # sabotage: the point clause's head is widened from
    # `[:statifier_persistence, _phase, _kind]` to
    # `[:statifier_persistence | _rest]` -> red (a step start with no
    # `span_ref` becomes a point span for a pair that never opened,
    # instead of being dropped)
    test "a malformed event drops rather than raising" do
      :telemetry.execute(
        [:statifier_persistence, :execution, :step, :start],
        %{},
        %{execution_id: "exec-7"}
      )

      refute_receive {:span, _span}, 50

      assert [_handler] =
               :telemetry.list_handlers([:statifier_persistence, :execution, :step, :start])
    end
  end
end
