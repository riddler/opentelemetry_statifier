defmodule OpentelemetryStatifier.ReadmeExampleTest.AuthorizeHandler do
  @moduledoc """
  The invoke handler the README's "Invoking an authorization service"
  snippet shows, kept here so the snippet is executed rather than asserted
  by eye.

  `start/2`, `cancel/2` and `forward/3` are the pure planning half of
  `Statifier.Invoke.Handler`; `perform/2` is the impure half and receives
  the *payload* of a `{:handler, module, payload}` instruction, not the
  instruction tuple.
  """

  @behaviour Statifier.Invoke.Handler

  @impl Statifier.Invoke.Handler
  def start(invoke, _ctx), do: {:ok, [{:handler, __MODULE__, {:authorize, invoke.invoke_id}}]}

  @impl Statifier.Invoke.Handler
  def cancel(_invoke_id, _ctx), do: {:ok, []}

  @impl Statifier.Invoke.Handler
  def forward(_invoke_id, _event, _ctx), do: {:ok, []}

  # Idempotent by contract: the session may call this more than once for the
  # same invoke_id. Sending a real authorization request would happen here.
  @impl Statifier.Invoke.Handler
  def perform({:authorize, _invoke_id}, _ctx), do: :ok
end

defmodule OpentelemetryStatifier.ReadmeExampleTest do
  @moduledoc """
  Executes the README's worked examples end to end against a real
  `Statifier.Session`, so a snippet that stops matching the library fails
  the gate instead of going quietly stale.

  This is the only place in the suite that drives the bridge through a live
  session rather than hand-emitted `:telemetry.execute/3` calls: the other
  test files exercise the mapping in isolation, this one proves the whole
  path from SCXML source to exported spans.

  When the README's charts, snippets, or the span shapes it prints change,
  change them here in the same commit.
  """

  # Global state twice over: `:telemetry`'s handler registry, and the
  # `:otel_simple_processor` exporter SpanCapture points at the test
  # process.
  use ExUnit.Case, async: false

  import OpentelemetryStatifier.SpanCapture

  alias OpentelemetryStatifier.ReadmeExampleTest.AuthorizeHandler
  alias OpentelemetryStatifier.SpanCapture
  alias OpentelemetryStatifier.SpanTable

  # Card processing, one of the family's two canonical example domains. Kept
  # byte-for-byte in step with the README's "A worked example" chart.
  @authorization_chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
    <state id="idle">
      <transition event="authorize.requested" target="authorizing"/>
    </state>
    <state id="authorizing">
      <onentry>
        <log label="card" expr="'authorizing'"/>
      </onentry>
      <transition event="authorization.approved" target="authorized"/>
      <transition event="authorization.declined" target="declined"/>
    </state>
    <state id="authorized">
      <transition event="capture.requested" target="captured"/>
    </state>
    <final id="captured"/>
    <final id="declined"/>
  </scxml>
  """

  # The same flow with the authorization delegated to a host-supplied
  # invoke handler, as the README's invoke snippet shows.
  @invoking_chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
    <state id="idle">
      <transition event="authorize.requested" target="authorizing"/>
    </state>
    <state id="authorizing">
      <invoke id="auth" type="myapp:authorize"/>
      <transition event="done.invoke.auth" target="authorized"/>
    </state>
    <state id="authorized">
      <transition event="capture.requested" target="captured"/>
    </state>
    <final id="captured"/>
  </scxml>
  """

  # Signup wizard with A/B testing, the family's other canonical example
  # domain. Here for the cardinality point the README makes: the variant is
  # chart vocabulary and lands in attributes, never in the span name.
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

  # sabotage: Handler's macrostep span name changed to "statifier.step" ->
  # red (every span-name assertion below fails)
  test "the README's authorization run emits one span per macrostep" do
    {:ok, machine} = Statifier.compile(@authorization_chart)
    {:ok, session} = Statifier.Session.start_link(machine, session_id: "sess_card")

    :ok = Statifier.Session.send_event(session, "authorize.requested")
    :ok = Statifier.Session.send_event(session, "authorization.approved")
    :ok = Statifier.Session.send_event(session, "capture.requested")

    # `send_event/2` is a cast; `status/1` is a call on the same process, so
    # it serializes behind all three and is the natural sync point.
    assert %{status: :done, configuration: configuration, macrostep: 4} =
             Statifier.Session.status(session)

    assert configuration == MapSet.new(["captured"])

    assert_receive {:span, initialize}
    assert_receive {:span, authorizing}
    assert_receive {:span, authorized}
    assert_receive {:span, captured}
    refute_receive {:span, _}

    # Span-name cardinality is one, whatever the chart's vocabulary.
    for captured_span <- [initialize, authorizing, authorized, captured] do
      assert span(captured_span, :name) == "statifier.macrostep"
    end

    assert %{
             "statifier.session_id" => "sess_card",
             "statifier.trigger" => "initialize",
             "statifier.outcome" => "quiescent",
             "statifier.configuration" => ["idle"],
             "statifier.macrostep" => 1
           } = attrs(initialize)

    # Each macrostep roots its own trace; the first has no predecessor to
    # link to and every later one links back to exactly one.
    assert link_count(initialize) == 0
    assert link_count(authorizing) == 1
    assert link_count(authorized) == 1
    assert link_count(captured) == 1

    assert %{
             "statifier.trigger" => "event",
             "statifier.event_name" => "authorize.requested",
             "statifier.configuration" => ["authorizing"],
             "statifier.macrostep" => 2
           } = attrs(authorizing)

    assert event_names(authorizing) == ["statifier.effect.log"]

    assert %{
             "statifier.label" => "card",
             "statifier.source.line" => 7,
             "statifier.source.column" => 7
           } = event_attrs(authorizing, "statifier.effect.log")

    assert %{"statifier.outcome" => "done", "statifier.macrostep" => 4} = attrs(captured)
    assert event_names(captured) == ["statifier.halt", "statifier.effect.done"]
  end

  # sabotage: Attributes' @never_serialized gained :invoke_id, so the invoke
  # id stopped reaching an attribute -> red
  test "the README's invoke snippet records invoke and cancel_invoke span events" do
    {:ok, machine} = Statifier.compile(@invoking_chart)

    {:ok, session} =
      Statifier.Session.start_link(machine,
        session_id: "sess_card",
        invoke_handlers: %{"myapp:authorize" => AuthorizeHandler}
      )

    :ok = Statifier.Session.send_event(session, "authorize.requested")
    assert %{configuration: configuration} = Statifier.Session.status(session)
    assert configuration == MapSet.new(["authorizing"])
    assert [%{invoke_id: "auth"}] = Statifier.Session.invocations(session)

    :ok = Statifier.Session.done_invocation(session, "auth", %{"code" => "approved"})
    :ok = Statifier.Session.send_event(session, "capture.requested")
    assert %{status: :done} = Statifier.Session.status(session)

    assert_receive {:span, _initialize}
    assert_receive {:span, authorizing}
    assert_receive {:span, authorized}
    assert_receive {:span, _captured}

    assert event_names(authorizing) == ["statifier.effect.invoke"]

    assert %{"statifier.invoke_id" => "auth"} =
             event_attrs(authorizing, "statifier.effect.invoke")

    # Leaving the invoking state cancels the invocation, and that is a span
    # event on the macrostep that left it.
    assert event_names(authorized) == ["statifier.effect.cancel_invoke"]

    assert %{"statifier.invoke_id" => "auth"} =
             event_attrs(authorized, "statifier.effect.cancel_invoke")
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
