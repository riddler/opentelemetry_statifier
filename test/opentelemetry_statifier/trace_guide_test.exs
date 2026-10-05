defmodule OpentelemetryStatifier.TraceGuideTest do
  @moduledoc """
  Executes the result lines of the guide
  `docs/guides/how-to-see-a-chart-execution-as-a-trace.md` against a live
  `Statifier.Session`, so a step whose stated result stops holding fails
  the gate instead of going quietly stale.

  The loan chart is the README's Basic usage chart, which
  `OpentelemetryStatifier.ReadmeExampleTest` already pins against the
  README; the step that follows a child's link to its invoking parent is
  executed by `OpentelemetryStatifier.LinksTest`.

  When the guide's steps or the results they state change, change them
  here in the same commit.
  """

  # Global state twice over: `:telemetry`'s handler registry, and the
  # `:otel_simple_processor` exporter SpanCapture points at the test
  # process.
  use ExUnit.Case, async: false

  import OpentelemetryStatifier.SpanCapture

  alias OpentelemetryStatifier.SpanCapture
  alias OpentelemetryStatifier.SpanTable

  @guide "docs/guides/how-to-see-a-chart-execution-as-a-trace.md"

  @loan_chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="on_shelf">
    <state id="on_shelf">
      <transition event="loan.checked_out" target="on_loan"/>
    </state>
    <state id="on_loan">
      <onentry>
        <log label="loan" expr="'on loan'"/>
      </onentry>
      <transition event="loan.renewed" target="on_loan"/>
      <transition event="loan.returned" target="returned"/>
      <transition event="loan.lost" target="lost"/>
    </state>
    <final id="returned"/>
    <final id="lost"/>
  </scxml>
  """

  setup context do
    SpanCapture.start(context)

    table = :"trace_guide_test_#{System.unique_integer([:positive])}"
    SpanTable.new_table(table)
    :ok = OpentelemetryStatifier.setup(table: table)

    :ok
  end

  defp attrs(captured), do: captured |> span(:attributes) |> SpanCapture.attributes()

  defp link_targets(captured) do
    captured
    |> span(:links)
    |> SpanCapture.links()
    |> Enum.map(fn l -> {link(l, :trace_id), link(l, :span_id)} end)
  end

  defp event_attrs(captured, name) do
    captured
    |> span(:events)
    |> SpanCapture.events()
    |> Enum.find(&(event(&1, :name) == name))
    |> event(:attributes)
    |> SpanCapture.attributes()
  end

  # sabotage: the guide's step 2 snippet changed its session id to
  # "loan_7" -> red
  test "the guide carries the calls this file executes" do
    guide = File.read!(@guide)

    for line <- [
          ~s{:ok = OpentelemetryStatifier.setup()},
          ~s{Statifier.Session.start_link(machine, session_id: "loan_42")}
        ] do
      assert String.contains?(guide, line)
    end
  end

  # sabotage: OpentelemetryStatifier.setup/1's attach loop replaced with
  # :ok, so nothing attaches -> red
  test "step 1: setup lists the bridge's handlers on the macrostep events" do
    ids =
      [:statifier, :session, :macrostep]
      |> :telemetry.list_handlers()
      |> Enum.map(& &1.id)

    assert {OpentelemetryStatifier, [:statifier, :session, :macrostep, :start]} in ids
    assert {OpentelemetryStatifier, [:statifier, :session, :macrostep, :stop]} in ids
  end

  # sabotage: Handler's macrostep_links/3 returns [] -> red (the link
  # chain from the last macrostep back to the first breaks)
  test "steps 2 to 5: one execution found by its session id and followed by its links" do
    {:ok, machine} = Statifier.compile(@loan_chart)
    {:ok, session} = Statifier.Session.start_link(machine, session_id: "loan_42")

    :ok = Statifier.Session.send_event(session, "loan.checked_out")
    :ok = Statifier.Session.send_event(session, "loan.renewed")
    :ok = Statifier.Session.send_event(session, "loan.returned")
    assert %{status: :done} = Statifier.Session.status(session)

    spans =
      for _ <- 1..4 do
        assert_receive {:span, captured}
        captured
      end

    refute_receive {:span, _}

    # Step 2 and 3: every span carries the session id, is named
    # statifier.macrostep, roots its own trace, and is numbered 1 to 4.
    for captured <- spans do
      assert span(captured, :name) == "statifier.macrostep"
      assert span(captured, :parent_span_id) == :undefined
      assert %{"statifier.session_id" => "loan_42"} = attrs(captured)
    end

    assert spans |> Enum.map(&span(&1, :trace_id)) |> Enum.uniq() |> length() == 4

    by_number = Map.new(spans, &{attrs(&1)["statifier.macrostep"], &1})
    assert by_number |> Map.keys() |> Enum.sort() == [1, 2, 3, 4]

    # Step 4: the span whose outcome is done links to macrostep 3, each
    # link leads to the one before, and macrostep 1 has none.
    [done] = Enum.filter(spans, &(attrs(&1)["statifier.outcome"] == "done"))
    assert done == by_number[4]

    for n <- 2..4 do
      previous = by_number[n - 1]
      assert link_targets(by_number[n]) == [{span(previous, :trace_id), span(previous, :span_id)}]
    end

    assert %{"statifier.event_name" => "loan.renewed"} = attrs(by_number[3])
    assert %{"statifier.trigger" => "initialize"} = attrs(by_number[1])
    assert link_targets(by_number[1]) == []

    # Step 5: macrostep 2 is the check-out, and its log event points at
    # line 7 of the chart.
    assert %{"statifier.event_name" => "loan.checked_out"} = attrs(by_number[2])

    assert %{"statifier.source.line" => 7} =
             event_attrs(by_number[2], "statifier.effect.log")
  end
end
