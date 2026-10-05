defmodule OpentelemetryStatifier.ReadmeExampleTest.HoldCheckHandler do
  @moduledoc """
  The invoke handler behind the README's sentence on an `<invoke>` (a check
  for holds on the copy before it goes out), kept here so what that sentence
  says about the trace is executed rather than asserted by eye.

  `start/2`, `cancel/2` and `forward/3` are the pure planning half of
  `Statifier.Invoke.Handler`; `perform/2` is the impure half and receives
  the *payload* of a `{:handler, module, payload}` instruction, not the
  instruction tuple.
  """

  @behaviour Statifier.Invoke.Handler

  @impl Statifier.Invoke.Handler
  def start(invoke, _ctx), do: {:ok, [{:handler, __MODULE__, {:check_holds, invoke.invoke_id}}]}

  @impl Statifier.Invoke.Handler
  def cancel(_invoke_id, _ctx), do: {:ok, []}

  @impl Statifier.Invoke.Handler
  def forward(_invoke_id, _event, _ctx), do: {:ok, []}

  # Idempotent by contract: the session may call this more than once for the
  # same invoke_id. Asking the catalogue for holds would happen here.
  @impl Statifier.Invoke.Handler
  def perform({:check_holds, _invoke_id}, _ctx), do: :ok
end

defmodule OpentelemetryStatifier.ReadmeExampleTest do
  @moduledoc """
  Executes the README's Basic usage snippet end to end against a real
  `Statifier.Session`, so a snippet that stops matching the library fails
  the gate instead of going quietly stale. The chart is copied here, and a
  guard test reads the README to prove the copy still matches it.

  This is the only place in the suite that drives the bridge through a live
  session rather than hand-emitted `:telemetry.execute/3` calls: the other
  test files exercise the mapping in isolation, this one proves the whole
  path from SCXML source to exported spans.

  When the README's chart, snippet, or the span shapes it prints change,
  change them here in the same commit.
  """

  # Global state twice over: `:telemetry`'s handler registry, and the
  # `:otel_simple_processor` exporter SpanCapture points at the test
  # process.
  use ExUnit.Case, async: false

  import OpentelemetryStatifier.SpanCapture

  alias OpentelemetryStatifier.ReadmeExampleTest.HoldCheckHandler
  alias OpentelemetryStatifier.SpanCapture
  alias OpentelemetryStatifier.SpanTable

  # The library loan, the README's example world. Kept byte-for-byte in step
  # with the chart inside the README's Basic usage snippet; the guard test
  # below fails when the two part.
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

  # A loan whose check-out waits on a host-supplied invoke handler (a check
  # for holds on the copy), for the README's sentence on an `<invoke>`.
  @invoking_chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="on_shelf">
    <state id="on_shelf">
      <transition event="loan.requested" target="checking_holds"/>
    </state>
    <state id="checking_holds">
      <invoke id="holds" type="myapp:check_holds"/>
      <transition event="done.invoke.holds" target="on_loan"/>
    </state>
    <state id="on_loan">
      <transition event="loan.returned" target="returned"/>
    </state>
    <final id="returned"/>
  </scxml>
  """

  # A fixture, not README text: a chart with two variant branches, kept for
  # the cardinality rule (chart vocabulary lands in attributes, never in the
  # span name).
  @signup_chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="assigning">
    <state id="assigning">
      <transition event="variant.a.assigned" target="plan_a"/>
      <transition event="variant.b.assigned" target="plan_b"/>
    </state>
    <state id="plan_a">
      <transition event="signup.completed" target="converted"/>
    </state>
    <state id="plan_b">
      <transition event="signup.completed" target="converted"/>
    </state>
    <final id="converted"/>
  </scxml>
  """

  setup context do
    SpanCapture.start(context)

    table = :"readme_example_test_#{System.unique_integer([:positive])}"
    SpanTable.new_table(table)
    :ok = OpentelemetryStatifier.setup(table: table)

    %{table: table}
  end

  defp attrs(captured), do: captured |> span(:attributes) |> SpanCapture.attributes()

  defp event_names(captured) do
    captured
    |> span(:events)
    |> SpanCapture.events()
    |> Enum.map(&event(&1, :name))
  end

  defp event_attrs(captured, name) do
    captured
    |> span(:events)
    |> SpanCapture.events()
    |> Enum.find(&(event(&1, :name) == name))
    |> event(:attributes)
    |> SpanCapture.attributes()
  end

  defp link_count(captured), do: captured |> span(:links) |> SpanCapture.links() |> length()

  # The one code block under the README's "## Basic usage" heading.
  defp basic_usage_block do
    [_, section] = String.split(File.read!("README.md"), "\n## Basic usage\n", parts: 2)
    [section | _] = String.split(section, "\n## ", parts: 2)
    [[block]] = Regex.scan(~r/^```elixir\n(.*?)^```$/ms, section, capture: :all_but_first)
    block
  end

  # sabotage: the README's Basic usage chart gained a state the copy here
  # lacks -> red
  test "the README's Basic usage snippet carries the chart this file executes" do
    block = basic_usage_block()

    assert String.contains?(block, ~s(chart_source = """\n) <> @loan_chart <> ~s("""\n))

    for line <- [
          ~s{Statifier.Session.start_link(machine, session_id: "loan_42")},
          ~s{Statifier.Session.send_event(session, "loan.checked_out")},
          ~s{Statifier.Session.send_event(session, "loan.renewed")},
          ~s{Statifier.Session.send_event(session, "loan.returned")}
        ] do
      assert String.contains?(block, line)
    end
  end

  # sabotage: Handler's macrostep span name changed to "statifier.step" ->
  # red (every span-name assertion below fails)
  test "the README's loan emits one span per macrostep" do
    {:ok, machine} = Statifier.compile(@loan_chart)
    {:ok, session} = Statifier.Session.start_link(machine, session_id: "loan_42")

    :ok = Statifier.Session.send_event(session, "loan.checked_out")
    :ok = Statifier.Session.send_event(session, "loan.renewed")
    :ok = Statifier.Session.send_event(session, "loan.returned")

    # `send_event/2` is a cast; `status/1` is a call on the same process, so
    # it serializes behind all three and is the natural sync point.
    assert %{status: :done, configuration: configuration, macrostep: 4} =
             Statifier.Session.status(session)

    assert configuration == MapSet.new(["returned"])

    assert_receive {:span, initialize}
    assert_receive {:span, checked_out}
    assert_receive {:span, renewed}
    assert_receive {:span, returned}
    refute_receive {:span, _}

    # Span-name cardinality is one, whatever the chart's vocabulary.
    for captured_span <- [initialize, checked_out, renewed, returned] do
      assert span(captured_span, :name) == "statifier.macrostep"
      assert %{"statifier.session_id" => "loan_42"} = attrs(captured_span)
    end

    # `statifier.driver` end to end: the real interpreter emits
    # `driver: :session` (st-ADR-0067 decision 4) and the bridge maps it, so
    # a backend tells a session-hosted macrostep from a durable one.
    assert %{
             "statifier.trigger" => "initialize",
             "statifier.outcome" => "quiescent",
             "statifier.configuration" => ["on_shelf"],
             "statifier.macrostep" => 1,
             "statifier.driver" => "session"
           } = attrs(initialize)

    assert event_names(initialize) == ["statifier.effect.datamodel_init"]

    # Each macrostep roots its own trace; the first has no predecessor to
    # link to and every later one links back to exactly one.
    assert link_count(initialize) == 0
    assert link_count(checked_out) == 1
    assert link_count(renewed) == 1
    assert link_count(returned) == 1

    assert %{
             "statifier.trigger" => "event",
             "statifier.event_name" => "loan.checked_out",
             "statifier.configuration" => ["on_loan"],
             "statifier.macrostep" => 2
           } = attrs(checked_out)

    assert event_names(checked_out) == ["statifier.effect.log"]

    assert %{
             "statifier.label" => "loan",
             "statifier.source.line" => 7,
             "statifier.source.column" => 7
           } = event_attrs(checked_out, "statifier.effect.log")

    # The renewal is an external self-transition: it leaves and re-enters
    # on_loan, so the entry log fires again.
    assert %{
             "statifier.trigger" => "event",
             "statifier.event_name" => "loan.renewed",
             "statifier.configuration" => ["on_loan"]
           } = attrs(renewed)

    assert event_names(renewed) == ["statifier.effect.log"]

    assert %{
             "statifier.trigger" => "event",
             "statifier.event_name" => "loan.returned",
             "statifier.outcome" => "done",
             "statifier.macrostep" => 4
           } = attrs(returned)

    assert event_names(returned) == ["statifier.halt", "statifier.effect.done"]
  end

  # sabotage: Attributes' @never_serialized gained :invoke_id, so the invoke
  # id stopped reaching an attribute -> red
  test "the README's invoke sentence: invoke and cancel_invoke span events" do
    {:ok, machine} = Statifier.compile(@invoking_chart)

    {:ok, session} =
      Statifier.Session.start_link(machine,
        session_id: "loan_43",
        invoke_handlers: %{"myapp:check_holds" => HoldCheckHandler}
      )

    :ok = Statifier.Session.send_event(session, "loan.requested")
    assert %{configuration: configuration} = Statifier.Session.status(session)
    assert configuration == MapSet.new(["checking_holds"])
    assert [%{invoke_id: "holds"}] = Statifier.Session.invocations(session)

    :ok = Statifier.Session.done_invocation(session, "holds", %{"holds" => 0})
    :ok = Statifier.Session.send_event(session, "loan.returned")
    assert %{status: :done} = Statifier.Session.status(session)

    assert_receive {:span, _initialize}
    assert_receive {:span, checking_holds}
    assert_receive {:span, on_loan}
    assert_receive {:span, _returned}

    assert event_names(checking_holds) == ["statifier.effect.invoke"]

    assert %{"statifier.invoke_id" => "holds"} =
             event_attrs(checking_holds, "statifier.effect.invoke")

    # Leaving the invoking state cancels the invocation, and that is a span
    # event on the macrostep that left it.
    assert event_names(on_loan) == ["statifier.effect.cancel_invoke"]

    assert %{"statifier.invoke_id" => "holds"} =
             event_attrs(on_loan, "statifier.effect.cancel_invoke")
  end

  # sabotage: Handler's stop attributes renamed "statifier.configuration" to
  # "statifier.config", so the variant's state id moved -> red
  test "an A/B variant lands in attributes, not in the span name" do
    {:ok, machine} = Statifier.compile(@signup_chart)
    {:ok, session} = Statifier.Session.start_link(machine, session_id: "sess_readme_signup")

    :ok = Statifier.Session.send_event(session, "variant.a.assigned")
    :ok = Statifier.Session.send_event(session, "signup.completed")
    assert %{status: :done} = Statifier.Session.status(session)

    assert_receive {:span, _assigning}
    assert_receive {:span, assigned}
    assert_receive {:span, converted}

    assert span(assigned, :name) == "statifier.macrostep"

    assert %{
             "statifier.event_name" => "variant.a.assigned",
             "statifier.configuration" => ["plan_a"]
           } = attrs(assigned)

    assert %{"statifier.event_name" => "signup.completed", "statifier.outcome" => "done"} =
             attrs(converted)
  end
end
