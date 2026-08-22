defmodule OpentelemetryStatifier.SpanEventsTest do
  # Global state twice over: `:telemetry`'s handler registry, and the
  # `:otel_simple_processor` exporter SpanCapture points at the test
  # process.
  use ExUnit.Case, async: false

  import OpentelemetryStatifier.SpanCapture

  alias OpentelemetryStatifier.SpanCapture
  alias Statifier.Parser.Location

  setup context do
    SpanCapture.start(context)

    table = :"span_events_test_#{System.unique_integer([:positive])}"
    OpentelemetryStatifier.SpanTable.new_table(table)
    :ok = OpentelemetryStatifier.setup(table: table)

    %{table: table}
  end

  defp emit_start(session_id, span_ref, monotonic_time \\ System.monotonic_time()) do
    :telemetry.execute(
      [:statifier, :session, :macrostep, :start],
      %{system_time: System.system_time(), monotonic_time: monotonic_time},
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

  defp span_events(captured) do
    captured
    |> span(:events)
    |> SpanCapture.events()
    |> Enum.map(fn evt ->
      {event(evt, :name), SpanCapture.attributes(event(evt, :attributes))}
    end)
  end

  defp location do
    %Location{
      start_line: 3,
      start_column: 7,
      start_offset: 40,
      end_line: 3,
      end_column: 20,
      end_offset: 53
    }
  end

  # sabotage: Attributes.put_metadata/4's :location clause is removed (the
  # struct then falls to put_scalar/3 and is dropped) -> red on the
  # statifier.source.line/column keys below
  test "an effect event lands as a span event with uniformly mapped attributes" do
    span_ref = make_ref()
    emit_start("session-e1", span_ref)

    :telemetry.execute(
      [:statifier, :session, :effect, :send],
      %{macrostep: 1, microstep: 2, round: 0},
      %{
        session_id: "session-e1",
        effect: {:raw, :effect, :struct},
        location: location(),
        send_id: "send-1",
        target: "#_internal",
        c_index: 4,
        owner: {:onentry, 2, 0}
      }
    )

    emit_stop("session-e1", span_ref)
    assert_receive {:span, captured}

    assert [{"statifier.effect.send", attributes}] = span_events(captured)

    assert attributes == %{
             "statifier.macrostep" => 1,
             "statifier.microstep" => 2,
             "statifier.round" => 0,
             "statifier.session_id" => "session-e1",
             "statifier.source.line" => 3,
             "statifier.source.column" => 7,
             "statifier.send_id" => "send-1",
             "statifier.target" => "#_internal",
             "statifier.c_index" => 4,
             "statifier.owner" => "{:onentry, 2, 0}"
           }
  end

  # sabotage: Attributes.put_metadata/4's nil clause is removed -> red (nil
  # falls to put_scalar/3's atom clause and lands as the string "nil" under
  # statifier.location / statifier.c_index)
  test "nil metadata values are omitted rather than encoded" do
    span_ref = make_ref()
    emit_start("session-e2", span_ref)

    :telemetry.execute(
      [:statifier, :session, :effect, :cancel],
      %{macrostep: 1, microstep: 1, round: 0, ordinal: 2},
      %{
        session_id: "session-e2",
        effect: :raw,
        location: nil,
        send_id: "send-9",
        c_index: nil,
        owner: nil
      }
    )

    emit_stop("session-e2", span_ref)
    assert_receive {:span, captured}

    assert [{"statifier.effect.cancel", attributes}] = span_events(captured)

    assert attributes == %{
             "statifier.macrostep" => 1,
             "statifier.microstep" => 1,
             "statifier.round" => 0,
             "statifier.ordinal" => 2,
             "statifier.session_id" => "session-e2",
             "statifier.send_id" => "send-9"
           }
  end

  # sabotage: Attributes.put_metadata/4's :configuration clause is removed
  # -> red (the MapSet falls to put_scalar/3 and is dropped)
  test "configuration on :effect, :done becomes a sorted string-array attribute" do
    span_ref = make_ref()
    emit_start("session-e3", span_ref)

    :telemetry.execute(
      [:statifier, :session, :effect, :done],
      %{macrostep: 2, microstep: 4, round: 1},
      %{
        session_id: "session-e3",
        effect: :raw,
        location: nil,
        configuration: MapSet.new(["b", "a", "c"])
      }
    )

    emit_stop("session-e3", span_ref)
    assert_receive {:span, captured}

    assert [{"statifier.effect.done", attributes}] = span_events(captured)
    assert attributes["statifier.configuration"] == ["a", "b", "c"]
  end

  # sabotage: Attributes.put_metadata/4's datamodel clause ignores the
  # config and always records -> red on the refutations below
  test "datamodel values are excluded by default; write identity is kept" do
    span_ref = make_ref()
    emit_start("session-e4", span_ref)

    :telemetry.execute(
      [:statifier, :session, :effect, :datamodel_change],
      %{macrostep: 1, microstep: 1, round: 0},
      %{
        session_id: "session-e4",
        effect: :raw,
        location: location(),
        location_path: "user.name",
        location_source: :assign,
        new_value: "Ada",
        prior_value: "Grace",
        d_index: nil,
        c_index: 6,
        owner: {:transition, 1}
      }
    )

    :telemetry.execute(
      [:statifier, :session, :effect, :datamodel_init],
      %{macrostep: 0, microstep: 0, round: 0},
      %{session_id: "session-e4", effect: :raw, location: nil, datamodel: %{"k" => "v"}}
    )

    emit_stop("session-e4", span_ref)
    assert_receive {:span, captured}

    assert [
             {"statifier.effect.datamodel_change", change_attributes},
             {"statifier.effect.datamodel_init", init_attributes}
           ] = Enum.sort(span_events(captured))

    refute Map.has_key?(change_attributes, "statifier.new_value")
    refute Map.has_key?(change_attributes, "statifier.prior_value")
    refute Map.has_key?(init_attributes, "statifier.datamodel")

    assert change_attributes["statifier.location_path"] == "user.name"
    assert change_attributes["statifier.location_source"] == "assign"
    assert change_attributes["statifier.source.line"] == 3
    assert change_attributes["statifier.c_index"] == 6
  end

  # sabotage: Attributes' datamodel clause is changed to never record
  # (`if record?` -> `if false`) -> red
  test "record_datamodel_values: true records the values via inspect/1", %{table: table} do
    :ok = OpentelemetryStatifier.setup(table: table, record_datamodel_values: true)

    span_ref = make_ref()
    emit_start("session-e5", span_ref)

    :telemetry.execute(
      [:statifier, :session, :effect, :datamodel_change],
      %{macrostep: 1, microstep: 1, round: 0},
      %{
        session_id: "session-e5",
        effect: :raw,
        location: nil,
        location_path: "count",
        location_source: :assign,
        new_value: 42,
        prior_value: %{"nested" => true},
        d_index: nil,
        c_index: 1,
        owner: {:onexit, 0, 0}
      }
    )

    emit_stop("session-e5", span_ref)
    assert_receive {:span, captured}

    assert [{"statifier.effect.datamodel_change", attributes}] = span_events(captured)
    assert attributes["statifier.new_value"] == "42"
    assert attributes["statifier.prior_value"] == inspect(%{"nested" => true})
  end

  # sabotage: the handler's family clause builds the name as
  # "statifier.effect.#{kind}" for :trace too -> red on the event name
  test "a trace event lands as statifier.trace.<kind> with its size measurement" do
    span_ref = make_ref()
    emit_start("session-e6", span_ref)

    :telemetry.execute(
      [:statifier, :session, :trace, :exit_set],
      %{macrostep: 1, microstep: 3, round: 2, size: 2},
      %{session_id: "session-e6", effect: :raw}
    )

    emit_stop("session-e6", span_ref)
    assert_receive {:span, captured}

    assert [{"statifier.trace.exit_set", attributes}] = span_events(captured)

    assert attributes == %{
             "statifier.macrostep" => 1,
             "statifier.microstep" => 3,
             "statifier.round" => 2,
             "statifier.size" => 2,
             "statifier.session_id" => "session-e6"
           }
  end

  # sabotage: the handler's three-name clause guard drops :halt from its
  # `kind in [...]` list -> red (the halt event falls to the catch-all and
  # only two span events arrive)
  test ":interpret, :unroutable, and :halt land as span events on the open span" do
    span_ref = make_ref()
    emit_start("session-e7", span_ref)

    :telemetry.execute(
      [:statifier, :session, :interpret],
      %{effect_count: 4, macrostep: 1, microstep: 2},
      %{session_id: "session-e7"}
    )

    :telemetry.execute(
      [:statifier, :session, :unroutable],
      %{macrostep: 1, microstep: 2},
      %{
        session_id: "session-e7",
        effect: :raw,
        target: "#_scxml_missing",
        send_id: "send-3",
        location: location()
      }
    )

    :telemetry.execute(
      [:statifier, :session, :halt],
      %{macrostep: 1, microstep: 2, round: 0},
      %{session_id: "session-e7", reason: :done, configuration: MapSet.new(["final"])}
    )

    emit_stop("session-e7", span_ref)
    assert_receive {:span, captured}

    events = span_events(captured)

    assert Enum.map(events, &elem(&1, 0)) |> Enum.sort() ==
             ["statifier.halt", "statifier.interpret", "statifier.unroutable"]

    {_name, halt_attributes} = List.keyfind(events, "statifier.halt", 0)
    assert halt_attributes["statifier.reason"] == "done"
    assert halt_attributes["statifier.configuration"] == ["final"]

    {_name, unroutable_attributes} = List.keyfind(events, "statifier.unroutable", 0)
    assert unroutable_attributes["statifier.target"] == "#_scxml_missing"
    assert unroutable_attributes["statifier.source.line"] == 3
  end

  # sabotage: add_span_event/5's :error branch is changed to raise -> red
  # (the handler would be detached, so the attached-handler assertion fails)
  test "an effect event with no open span is dropped and the handler stays attached" do
    :telemetry.execute(
      [:statifier, :session, :effect, :log],
      %{macrostep: 1, microstep: 1, round: 0},
      %{session_id: "session-e8", effect: :raw, location: nil, label: "hello"}
    )

    refute_receive {:span, _}

    assert {OpentelemetryStatifier, [:statifier, :session, :effect, :log]} in handler_ids()
  end

  # sabotage: SpanTable.fetch_innermost_open_span/2 changed to Enum.min_by
  # -> red (the event lands on the outer span instead)
  test "with two spans open for one session, an event lands on the innermost" do
    span_ref_outer = make_ref()
    span_ref_inner = make_ref()
    start_time = System.monotonic_time()

    emit_start("session-e9", span_ref_outer, start_time)
    emit_start("session-e9", span_ref_inner, start_time + 1_000)

    :telemetry.execute(
      [:statifier, :session, :effect, :log],
      %{macrostep: 2, microstep: 1, round: 0},
      %{session_id: "session-e9", effect: :raw, location: nil, label: "inner"}
    )

    emit_stop("session-e9", span_ref_inner)
    emit_stop("session-e9", span_ref_outer)

    assert_receive {:span, inner_closed}
    assert_receive {:span, outer_closed}

    assert [{"statifier.effect.log", _attributes}] = span_events(inner_closed)
    assert span_events(outer_closed) == []
  end

  defp handler_ids do
    :telemetry.list_handlers([:statifier])
    |> Enum.map(& &1.id)
  end
end
