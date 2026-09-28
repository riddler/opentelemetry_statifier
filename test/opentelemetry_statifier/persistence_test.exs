defmodule OpentelemetryStatifier.PersistenceTest do
  # Global state twice over: `:telemetry`'s handler registry, and the
  # `:otel_simple_processor` exporter SpanCapture points at the test
  # process.
  use ExUnit.Case, async: false

  import OpentelemetryStatifier.SpanCapture

  alias OpentelemetryStatifier.{Persistence, SpanCapture, SpanTable}
  alias OpentelemetryStatifier.Persistence.Handler
  alias StatifierPersistence.{Executions, Storage}
  alias StatifierPersistence.Migration.Plan

  # sabotage: events/0's doctest expects 24 where the list holds 23 -> red
  doctest OpentelemetryStatifier.Persistence

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
      assert length(Persistence.events()) == 23

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

      # sabotage: the set_status call is deleted from the step-exception
      # clause -> red (the span closes unset, and a failed drive reads as
      # a clean one)
      assert {:status, :error, message} = span(step, :status)

      # The two renderings of `reason` are deliberate and both published:
      # the status message is the readable form, the `reason` attribute
      # (and `exception.type`, pinned in the next test) keeps the
      # `Elixir.` prefix. The Persistence moduledoc says why.
      # sabotage: format_term/1 stops stripping the prefix -> red (the
      # message reads "error: Elixir.RuntimeError")
      assert message == "error: RuntimeError"

      attributes = SpanCapture.attributes(span(step, :attributes))
      assert attributes["statifier_persistence.kind"] == "error"
      assert attributes["statifier_persistence.reason"] == "Elixir.RuntimeError"
      assert attributes["statifier_persistence.duration"] == 777
      refute Map.has_key?(attributes, "statifier_persistence.stacktrace")
    end

    # sabotage: the add_event call is deleted from the step-exception
    # clause -> red (the step span closes with an error status and no
    # span event, and a backend's exception view shows nothing)
    test "a step exception records an exception span event on the step span" do
      span_ref = make_ref()

      emit_step_start("exec-8e", span_ref)

      :telemetry.execute(
        [:statifier_persistence, :execution, :step, :exception],
        %{duration: 777, monotonic_time: System.monotonic_time()},
        %{
          execution_id: "exec-8e",
          entry: :step,
          span_ref: span_ref,
          kind: :error,
          reason: RuntimeError,
          stacktrace: [
            {Some.Executor, :run, 2, [file: ~c"lib/some.ex", line: 7]},
            {Some.Builder, :build, 1, []}
          ]
        }
      )

      assert_receive {:span, step}
      assert span(step, :name) == "statifier_persistence.execution.step"

      assert [{"exception", attributes}] = span_events(step)
      assert attributes["exception.type"] == "Elixir.RuntimeError"

      # sabotage: format_stacktrace/1 joins the frames with inspect/1
      # instead of formatting each entry -> red (the event carries the
      # raw tuples, not the frames a backend's exception view reads)
      assert attributes["exception.stacktrace"] ==
               "    lib/some.ex:7: Some.Executor.run/2\n    Some.Builder.build/1\n"

      assert map_size(attributes) == 2
    end

    # sabotage: format_frame/1's inspect/1 fallback clause is deleted ->
    # red (a `:redacted` frame raises inside the handler, :telemetry
    # detaches it, and the step span is never closed or exported)
    test "a throw's exception event renders its kind and survives a redacted frame" do
      span_ref = make_ref()

      emit_step_start("exec-8t", span_ref)

      :telemetry.execute(
        [:statifier_persistence, :execution, :step, :exception],
        %{duration: 1, monotonic_time: System.monotonic_time()},
        %{
          execution_id: "exec-8t",
          entry: :step,
          span_ref: span_ref,
          kind: :throw,
          reason: :redacted,
          stacktrace: [:redacted, {Some.Executor, :run, 2, [file: ~c"lib/some.ex", line: 7]}]
        }
      )

      assert_receive {:span, step}
      assert [{"exception", attributes}] = span_events(step)
      assert attributes["exception.type"] == "throw:redacted"

      assert attributes["exception.stacktrace"] ==
               "    :redacted\n    lib/some.ex:7: Some.Executor.run/2\n"

      assert [_handler] =
               :telemetry.list_handlers([:statifier_persistence, :execution, :step, :exception])
    end

    # sabotage: exception_event_attributes/1 always puts
    # "exception.stacktrace", formatting a missing stacktrace as "" -> red
    # (an event with no frames claims an empty trace instead of omitting it)
    test "an exit with no frames records the event without a stacktrace" do
      span_ref = make_ref()

      emit_step_start("exec-8x", span_ref)

      :telemetry.execute(
        [:statifier_persistence, :execution, :step, :exception],
        %{duration: 1, monotonic_time: System.monotonic_time()},
        %{execution_id: "exec-8x", entry: :step, span_ref: span_ref, kind: :exit, reason: :normal}
      )

      assert_receive {:span, step}
      assert {:status, :error, "exit: normal"} = span(step, :status)

      assert [{"exception", %{"exception.type" => "exit:normal"} = attributes}] =
               span_events(step)

      refute Map.has_key?(attributes, "exception.stacktrace")
    end

    # sabotage: the step-exception clause reads the entry under its
    # span_ref without deleting it (an :ets.lookup in place of
    # take_sibling_span/2) -> red (the span is exported but its entry
    # stays in the table, and the next event on this process nests under
    # a span that has already ended)
    test "a step exception takes the step span's entry out of the span table", %{
      table: table
    } do
      span_ref = make_ref()

      emit_step_start("exec-8k", span_ref)

      assert {:ok, _entry} = SpanTable.fetch_innermost_sibling_span(table, self())

      :telemetry.execute(
        [:statifier_persistence, :execution, :step, :exception],
        %{duration: 1, monotonic_time: System.monotonic_time()},
        %{execution_id: "exec-8k", entry: :step, span_ref: span_ref, kind: :throw, reason: :x}
      )

      assert_receive {:span, step}
      assert span(step, :name) == "statifier_persistence.execution.step"

      assert SpanTable.fetch_innermost_sibling_span(table, self()) == :error
      assert :ets.match_object(table, {{:sibling_span, :_}, :_, :_}) == []
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
      assert span_events(step) == []
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
          dropped: ["gone_b", "gone_a"]
        }
      )

      assert_receive {:span, migrated}
      assert span(migrated, :name) == "statifier_persistence.execution.migrated"

      attributes = SpanCapture.attributes(span(migrated, :attributes))
      assert attributes["statifier_persistence.execution_id"] == "exec-12"
      assert attributes["statifier_persistence.from_content_hash"] == "old"
      assert attributes["statifier_persistence.to_content_hash"] == "new"
      # The dropped state ids are a sorted string array, queryable the way
      # `configuration` is, not one inspect string.
      # sabotage: the dropped clause skips Enum.sort/1 -> red (the ids
      # arrive in emission order, "gone_b" first)
      # sabotage: :dropped is left to the attribute rules -> red (a list is
      # a shape the rules drop, and the key is absent)
      assert attributes["statifier_persistence.dropped"] == ["gone_a", "gone_b"]
    end

    # The OpenTelemetry API refuses an empty list as an attribute value, so
    # a migration that drops no state - the common case - carries no
    # `dropped` attribute at all, rather than an empty array.
    # sabotage: put_dropped/2 renders an empty list with inspect/1 -> red
    # (the attribute is present as the string "[]", as it was before the
    # array rendering)
    test "a migration that drops no state carries no dropped attribute" do
      :telemetry.execute(
        [:statifier_persistence, :execution, :migrated],
        %{system_time: System.system_time()},
        %{
          execution_id: "exec-12b",
          from_content_hash: "old",
          to_content_hash: "new",
          dropped: []
        }
      )

      assert_receive {:span, migrated}
      assert span(migrated, :name) == "statifier_persistence.execution.migrated"

      attributes = SpanCapture.attributes(span(migrated, :attributes))
      assert attributes["statifier_persistence.execution_id"] == "exec-12b"
      refute Map.has_key?(attributes, "statifier_persistence.dropped")
    end

    # A conforming event cannot carry this - state ids are strings by the
    # upstream contract - but a `dropped` list that is not all strings is
    # left in the metadata for the attribute rules, which drop a list: the
    # attribute is absent and the rest of the point survives. The elements
    # are atoms rather than a string mixed with a non-string because the
    # OpenTelemetry API itself refuses a list that is not homogeneous, so
    # only a homogeneous non-string list tells the fallback apart from the
    # string-array rendering.
    # sabotage: pop_dropped/1 takes any list, skipping its all-strings
    # check -> red (the atoms export as a sorted array under the dropped
    # key)
    test "a dropped list that is not all strings carries no dropped attribute" do
      :telemetry.execute(
        [:statifier_persistence, :execution, :migrated],
        %{system_time: System.system_time()},
        %{
          execution_id: "exec-12c",
          from_content_hash: "old",
          to_content_hash: "new",
          dropped: [:gone_b, :gone_a]
        }
      )

      assert_receive {:span, migrated}
      assert span(migrated, :name) == "statifier_persistence.execution.migrated"

      attributes = SpanCapture.attributes(span(migrated, :attributes))
      assert attributes["statifier_persistence.execution_id"] == "exec-12c"
      assert attributes["statifier_persistence.to_content_hash"] == "new"
      refute Map.has_key?(attributes, "statifier_persistence.dropped")
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

  describe "the batch migration span" do
    # A library loan waits in `awaiting_return`; the next revision of its
    # document gives the check-in step a `damaged` outcome and changes
    # nothing a waiting loan stands on, so both loans move.
    @loan """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="awaiting_return">
      <state id="awaiting_return">
        <transition event="copy.returned" target="checking_in"/>
      </state>
      <state id="checking_in">
        <transition event="copy.checked" target="returned"/>
      </state>
      <final id="returned"/>
    </scxml>
    """

    @loan_checkin """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="awaiting_return">
      <state id="awaiting_return">
        <transition event="copy.returned" target="checking_in"/>
      </state>
      <state id="checking_in">
        <transition event="copy.checked" target="returned"/>
        <transition event="copy.damaged" target="damaged"/>
      </state>
      <final id="returned"/>
      <final id="damaged"/>
    </scxml>
    """

    defp quiet(_effect, _context), do: :ok

    # Two loans on the in-memory adapter, both on the first revision, and
    # the plan that moves them to the second.
    defp two_loans do
      {:ok, store} = Storage.new(Storage.InMemory, [])
      {:ok, from} = Statifier.compile(@loan)
      {:ok, to} = Statifier.compile(@loan_checkin)
      :ok = Storage.save_chart(store, from, @loan)
      :ok = Storage.save_chart(store, to, @loan_checkin)

      for id <- ["loan-a", "loan-b"] do
        {:ok, _execution, _ms} = Executions.create(store, id, from, executor: &quiet/2)
      end

      {:ok, plan} =
        Plan.new(from: from.identity.content_hash, to: to.identity.content_hash, states: %{})

      drain_spans()
      %{store: store, from: from, to: to, plan: plan}
    end

    defp migrate_batch(%{store: store, from: from, to: to, plan: plan}, opts) do
      Executions.migrate_batch(
        store,
        plan,
        [from_machine: from, to_machine: to] ++ opts
      )
    end

    defp drain_spans(acc \\ []) do
      receive do
        {:span, captured} -> drain_spans([captured | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp named(spans, name), do: Enum.filter(spans, &(span(&1, :name) == name))

    defp emit_batch_start(span_ref) do
      :telemetry.execute(
        [:statifier_persistence, :execution, :migrate_batch, :start],
        %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
        %{from: "loan-v1", to: "loan-v2", dry_run: false, span_ref: span_ref}
      )
    end

    # sabotage: the three migrate_batch names deleted from Persistence's
    # @events -> red (no batch span is exported; the migrated points
    # become two root spans of their own)
    test "a real apply over two executions exports one span with the report's counts" do
      loans = two_loans()

      assert {:ok, %{counts: counts}} = migrate_batch(loans, [])
      assert counts == %{migrated: 2, refused: 0, parked: 0, skipped: 0}

      spans = drain_spans()
      assert [batch] = named(spans, "statifier_persistence.execution.migrate_batch")
      assert span(batch, :parent_span_id) == :undefined
      assert span(batch, :status) == :undefined

      attributes = SpanCapture.attributes(span(batch, :attributes))
      assert attributes["statifier_persistence.from"] == loans.from.identity.content_hash
      assert attributes["statifier_persistence.to"] == loans.to.identity.content_hash
      assert attributes["statifier_persistence.dry_run"] == false
      assert attributes["statifier_persistence.outcome"] == "ok"
      refute Map.has_key?(attributes, "statifier_persistence.reason")
      assert is_integer(attributes["statifier_persistence.duration"])

      # One attribute per outcome of the mode, the zeros included.
      # sabotage: the stop clause closes with the metadata's attributes
      # alone (measurements passed as %{}) -> red (no count attribute)
      assert attributes["statifier_persistence.migrated"] == 2
      assert attributes["statifier_persistence.refused"] == 0
      assert attributes["statifier_persistence.parked"] == 0
      assert attributes["statifier_persistence.skipped"] == 0
      refute Map.has_key?(attributes, "statifier_persistence.monotonic_time")
    end

    # sabotage: the point clause hosts on :detached instead of
    # {:process, self()} -> red (each migrated execution becomes a root
    # span of its own and the batch span carries no event)
    test "each migrated execution lands as a span event on the batch span" do
      loans = two_loans()

      assert {:ok, _report} = migrate_batch(loans, [])

      spans = drain_spans()
      assert [batch] = named(spans, "statifier_persistence.execution.migrate_batch")
      assert named(spans, "statifier_persistence.execution.migrated") == []

      migrated =
        for {"statifier_persistence.execution.migrated", attributes} <- span_events(batch),
            do: attributes["statifier_persistence.execution_id"]

      assert Enum.sort(migrated) == ["loan-a", "loan-b"]
    end

    # The lock and adapter-call spans each execution's turn opens nest
    # inside the batch span, by the table rule a step span already obeys.
    # sabotage: open_span/6 records the span under a fresh pid instead of
    # the emitting one -> red (the interval spans find no enclosing span
    # and root their own traces)
    test "the spans each execution's turn opens nest inside the batch span" do
      loans = two_loans()

      assert {:ok, _report} = migrate_batch(loans, [])

      spans = drain_spans()
      assert [batch] = named(spans, "statifier_persistence.execution.migrate_batch")
      batch_id = span(batch, :span_id)

      inner =
        named(spans, "statifier_persistence.execution.lock") ++
          named(spans, "statifier_persistence.adapter.call")

      assert inner != []
      assert Enum.all?(inner, &(span(&1, :parent_span_id) == batch_id))
      assert Enum.all?(inner, &(span(&1, :trace_id) == span(batch, :trace_id)))
    end

    # sabotage: :migrate_batch removed from @paired_seams -> red (no
    # batch span is exported for the dry run)
    test "a dry run's span carries dry_run true, its counts, and no migrated event" do
      loans = two_loans()

      assert {:ok, %{counts: counts}} = migrate_batch(loans, dry_run: true)
      assert counts == %{would_migrate: 2, would_refuse: 0, skipped: 0}

      spans = drain_spans()
      assert [batch] = named(spans, "statifier_persistence.execution.migrate_batch")
      assert named(spans, "statifier_persistence.execution.migrated") == []

      attributes = SpanCapture.attributes(span(batch, :attributes))
      assert attributes["statifier_persistence.dry_run"] == true
      assert attributes["statifier_persistence.would_migrate"] == 2
      assert attributes["statifier_persistence.would_refuse"] == 0
      assert attributes["statifier_persistence.skipped"] == 0
      refute Map.has_key?(attributes, "statifier_persistence.migrated")

      refute Enum.any?(
               span_events(batch),
               &match?({"statifier_persistence.execution.migrated", _attributes}, &1)
             )
    end

    # A whole-batch refusal closes through `:stop` with `outcome: :error`,
    # the refusal as `reason` and every count of the mode at zero.
    # sabotage: the stop clause's guard narrowed to `seam == :step` -> red
    # (the refusal's close falls to the catch-all and the span never ends)
    test "a batch refused whole closes with its reason and every count at zero" do
      span_ref = make_ref()
      emit_batch_start(span_ref)

      :telemetry.execute(
        [:statifier_persistence, :execution, :migrate_batch, :stop],
        %{
          duration: 900,
          monotonic_time: System.monotonic_time(),
          migrated: 0,
          refused: 0,
          parked: 0,
          skipped: 0
        },
        %{
          from: "loan-v1",
          to: "loan-v2",
          dry_run: false,
          span_ref: span_ref,
          outcome: :error,
          reason: :content_hash_query_unsupported
        }
      )

      assert_receive {:span, batch}
      assert span(batch, :name) == "statifier_persistence.execution.migrate_batch"
      assert span(batch, :status) == :undefined

      attributes = SpanCapture.attributes(span(batch, :attributes))
      assert attributes["statifier_persistence.outcome"] == "error"
      assert attributes["statifier_persistence.reason"] == "content_hash_query_unsupported"

      assert Map.take(attributes, [
               "statifier_persistence.migrated",
               "statifier_persistence.refused",
               "statifier_persistence.parked",
               "statifier_persistence.skipped"
             ]) == %{
               "statifier_persistence.migrated" => 0,
               "statifier_persistence.refused" => 0,
               "statifier_persistence.parked" => 0,
               "statifier_persistence.skipped" => 0
             }
    end

    # sabotage: the exception clause's guard narrowed to `seam == :step`
    # -> red (the batch span stays open and nothing is exported)
    test "a batch exception fails the span with an error status and an exception event", %{
      table: table
    } do
      span_ref = make_ref()
      emit_batch_start(span_ref)

      :telemetry.execute(
        [:statifier_persistence, :execution, :migrate_batch, :exception],
        %{duration: 500, monotonic_time: System.monotonic_time()},
        %{
          from: "loan-v1",
          to: "loan-v2",
          dry_run: false,
          span_ref: span_ref,
          kind: :error,
          reason: RuntimeError,
          stacktrace: [{Some.Transform, :run, 2, [file: ~c"lib/some.ex", line: 7]}]
        }
      )

      assert_receive {:span, batch}
      assert span(batch, :name) == "statifier_persistence.execution.migrate_batch"
      assert {:status, :error, "error: RuntimeError"} = span(batch, :status)

      assert [{"exception", exception}] = span_events(batch)
      assert exception["exception.type"] == "Elixir.RuntimeError"

      attributes = SpanCapture.attributes(span(batch, :attributes))
      assert attributes["statifier_persistence.kind"] == "error"
      assert attributes["statifier_persistence.dry_run"] == false
      assert :error = SpanTable.take_sibling_span(table, span_ref)
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
