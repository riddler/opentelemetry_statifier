defmodule OpentelemetryStatifier.ObanTest do
  # Global state twice over: `:telemetry`'s handler registry, and the
  # `:otel_simple_processor` exporter SpanCapture points at the test
  # process.
  use ExUnit.Case, async: false

  import OpentelemetryStatifier.SpanCapture

  alias OpentelemetryStatifier.{Oban, SpanCapture, SpanTable}
  alias OpentelemetryStatifier.Oban.Handler

  @traceparent "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

  setup context do
    SpanCapture.start(context)

    table = :"oban_test_#{System.unique_integer([:positive])}"
    SpanTable.new_table(table)
    :ok = OpentelemetryStatifier.setup(table: table)
    :ok = Oban.setup(table: table)

    %{table: table}
  end

  defp emit_macrostep_start(session_id, span_ref) do
    :telemetry.execute(
      [:statifier, :session, :macrostep, :start],
      %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
      %{session_id: session_id, trigger: :event, event_name: "go", span_ref: span_ref}
    )
  end

  defp emit_macrostep_stop(session_id, span_ref) do
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

  defp emit_scheduled(scope, caller_context \\ nil) do
    :telemetry.execute(
      [:statifier_oban, :timer, :scheduled],
      %{system_time: System.system_time(), delay_ms: 5_000},
      %{
        scope: scope,
        send_id: "s1",
        ordinal: 1,
        macrostep: 1,
        microstep: 0,
        round: 0,
        scheduled_at: "2026-09-01T00:00:00Z",
        queue: :timers,
        conflict?: false,
        job_id: 99,
        caller_context: caller_context
      }
    )
  end

  defp emit_fired(scope, caller_context) do
    :telemetry.execute(
      [:statifier_oban, :timer, :fired],
      %{system_time: System.system_time(), attempt: 1},
      %{
        scope: scope,
        send_id: "s1",
        ordinal: 1,
        delivery: StatifierOban.Timer.Delivery.Session,
        job_id: 99,
        caller_context: caller_context
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

  defp span_links(captured) do
    captured
    |> span(:links)
    |> SpanCapture.links()
    |> Enum.map(fn l -> {link(l, :trace_id), link(l, :span_id)} end)
  end

  describe "attach discipline" do
    # sabotage: setup/1 attaches with :telemetry.attach_many/4 under one
    # shared id -> red (the per-event ids the assertion reads are absent)
    test "attaches one handler id per event name, ADR-0003 decision 2's discipline" do
      assert length(Oban.events()) == 11

      for event <- Oban.events() do
        assert [handler] = :telemetry.list_handlers(event)
        assert handler.id == {Oban, event}
        assert handler.function == (&Handler.handle_event/4)
      end
    end

    # sabotage: setup/1 drops its `:ok = teardown()` line -> red (the
    # second attach is refused as already_exists and the first call's
    # options stay in force, silently)
    test "setup/1 replaces rather than adding, and is independent of the other setups", %{
      table: table
    } do
      assert :ok = Oban.setup(table: table)
      replacement = :"#{table}_replacement"
      assert :ok = Oban.setup(table: replacement, record_datamodel_values: true)

      for event <- Oban.events() do
        assert [handler] = :telemetry.list_handlers(event)
        assert handler.config.table == replacement
        assert handler.config.record_datamodel_values
      end

      :ok = Oban.setup(table: table)

      # The interpreter family is untouched by this module's teardown.
      :ok = Oban.teardown()
      assert [_handler] = :telemetry.list_handlers([:statifier, :session, :macrostep, :start])
    end

    # sabotage: setup/1 attaches before validating opts -> red
    test "an invalid option attaches nothing" do
      :ok = Oban.teardown()

      assert {:error, {:invalid_option, :table, nil}} = Oban.setup(table: nil)
      assert :telemetry.list_handlers(hd(Oban.events())) == []
    end
  end

  describe "the scheduling seam" do
    # sabotage: the scheduling clause hosts on :detached -> red (the event
    # becomes its own span instead of landing on the macrostep span)
    test "lands as a span event on the macrostep span open in this process" do
      span_ref = make_ref()

      emit_macrostep_start("session-o1", span_ref)
      emit_scheduled("session-o1")
      emit_macrostep_stop("session-o1", span_ref)

      assert_receive {:span, macrostep}

      assert [{"statifier_oban.timer.scheduled", attributes}] = span_events(macrostep)
      assert attributes["statifier_oban.send_id"] == "s1"
      assert attributes["statifier_oban.conflict?"] == false
      assert attributes["statifier_oban.delay_ms"] == 5_000
      assert attributes["statifier_oban.job_id"] == 99

      # `scope` is renamed here, once, where the mapping is visible.
      assert attributes["statifier.session_id"] == "session-o1"
      refute Map.has_key?(attributes, "statifier_oban.scope")
    end

    # sabotage: open_host_span/2's session clause drops the
    # `pid == self()` guard -> red (the event lands on the span another
    # process holds for the same scope)
    test "never writes onto a span another process holds for the same scope", %{table: table} do
      parent = self()
      span_ref = make_ref()

      pid =
        spawn(fn ->
          emit_macrostep_start("session-o2", span_ref)
          send(parent, :started)

          receive do
            :stop ->
              emit_macrostep_stop("session-o2", span_ref)
              send(parent, :stopped)
          end
        end)

      assert_receive :started
      assert {:ok, ^pid} = SpanTable.fetch_session_pid(table, "session-o2")

      emit_scheduled("session-o2")

      assert_receive {:span, own}
      assert span(own, :name) == "statifier_oban.timer.scheduled"

      send(pid, :stop)
      assert_receive {:span, macrostep}
      assert span_events(macrostep) == []

      # Wait for the other process to leave the handler before this test
      # ends: the ETS table dies with the test process, and a handler
      # still inside it would raise and be detached for the VM's life.
      assert_receive :stopped
    end
  end

  describe "the delivery seam" do
    # sabotage: caller_context_links/1's traceparent clause returns [] ->
    # red (the fired timer is no longer linked to the arming trace)
    test "becomes its own span linked to the arming trace" do
      emit_fired("session-o3", %{"traceparent" => @traceparent})

      assert_receive {:span, fired}
      assert span(fired, :name) == "statifier_oban.timer.fired"

      # A link, never a parent: parenthood would hold the arming trace
      # open for the length of the delay.
      assert span(fired, :parent_span_id) == :undefined

      assert [{trace_id, span_id}] = span_links(fired)
      assert trace_id == 0x4BF92F3577B34DA6A3CE929D0E0E4736
      assert span_id == 0x00F067AA0BA902B7
    end

    # sabotage: caller_context is removed from the mapping's drop list ->
    # red (the opaque host term is flattened into an attribute)
    test "carries the delivery's identity, and never the caller context itself" do
      emit_fired("session-o3", %{"traceparent" => @traceparent})

      assert_receive {:span, fired}
      attributes = SpanCapture.attributes(span(fired, :attributes))

      assert attributes["statifier.session_id"] == "session-o3"
      assert attributes["statifier_oban.attempt"] == 1

      # A caller context the mapping would otherwise render - a plain
      # string, not the map form - still never becomes an attribute.
      emit_fired("session-o3", "an opaque host term")
      assert_receive {:span, stringy}
      stringy_attributes = SpanCapture.attributes(span(stringy, :attributes))
      refute Map.has_key?(stringy_attributes, "statifier_oban.caller_context")

      assert attributes["statifier_oban.delivery"] ==
               "Elixir.StatifierOban.Timer.Delivery.Session"

      refute Map.has_key?(attributes, "statifier_oban.caller_context")
    end

    # sabotage: caller_context_links/1's fallback clause raises instead of
    # returning [] -> red (a fire with no context loses its span)
    test "a fire with no caller context is simply unlinked" do
      emit_fired("session-o3", nil)

      assert_receive {:span, fired}
      assert span_links(fired) == []
    end

    # sabotage: remote_span_ctx/1 drops its `trace_id != 0` check -> red
    # (an all-zero traceparent becomes a link to nothing)
    test "an unreadable caller context links to nothing" do
      emit_fired("session-o4", %{
        "traceparent" => "00-#{String.duplicate("0", 32)}-00f067aa0ba902b7-01"
      })

      assert_receive {:span, zeroed}
      assert span_links(zeroed) == []

      emit_fired("session-o5", %{"host" => "term the bridge cannot read"})
      assert_receive {:span, opaque}
      assert span_links(opaque) == []
    end
  end
end
