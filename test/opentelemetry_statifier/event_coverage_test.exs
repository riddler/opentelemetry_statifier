defmodule OpentelemetryStatifier.EventCoverageTest do
  @moduledoc """
  The charter's exhaustiveness guard: every name
  `Statifier.Session.Telemetry.events/0` returns reaches a real
  `OpentelemetryStatifier.Handler` clause, not the catch-all.

  `OpentelemetryStatifierTest` already proves `setup/1` *attaches* to every
  name. Attaching is not mapping: the handler's last clause matches anything
  and returns `:ok`, so an event name this bridge has no clause for is
  swallowed silently and indistinguishably from one it handles. That is the
  right runtime behaviour - a bridge must never crash a session over an
  event it does not recognise - but it means upstream can add an event and
  this package will keep passing every other test in the suite while
  exporting nothing for it.

  The expectations below are derived from the event name by the same rule
  the handler uses, so an event added upstream grows an expectation here
  automatically and goes red until it is mapped. Nothing is hard-coded but
  the four names the design deliberately does not turn into span events.
  """

  # Global state twice over: `:telemetry`'s handler registry, and the
  # `:otel_simple_processor` exporter SpanCapture points at the test process.
  use ExUnit.Case, async: false

  import OpentelemetryStatifier.SpanCapture

  alias OpentelemetryStatifier.SpanCapture
  alias Statifier.Session.Telemetry

  # The four names that deliberately become neither a span nor a span event.
  # The macrostep pair opens and closes the span itself; `:init` fires before
  # any macrostep span exists (it only parks the invoke-parent context) and
  # `:terminate` after the last one (it only cleans up).
  @not_span_events [
    [:statifier, :session, :macrostep, :start],
    [:statifier, :session, :macrostep, :stop],
    [:statifier, :session, :init],
    [:statifier, :session, :terminate]
  ]

  setup context do
    SpanCapture.start(context)

    table = :"event_coverage_test_#{System.unique_integer([:positive])}"
    OpentelemetryStatifier.SpanTable.new_table(table)
    :ok = OpentelemetryStatifier.setup(table: table)

    %{table: table}
  end

  defp span_event_names do
    Enum.reject(Telemetry.events(), &(&1 in @not_span_events))
  end

  # The handler's own naming rule, restated: a four-segment name is
  # `statifier.<family>.<kind>`, a three-segment one `statifier.<kind>`.
  defp expected_span_event_name([:statifier, :session, family, kind]),
    do: "statifier.#{family}.#{kind}"

  defp expected_span_event_name([:statifier, :session, kind]), do: "statifier.#{kind}"

  # sabotage: the handler's `family in [:effect, :trace]` clause deleted ->
  # red, with all twenty effect/trace names reported missing
  test "every telemetry event the design maps lands as a span event on the macrostep span" do
    session_id = "session-coverage"
    span_ref = make_ref()

    :telemetry.execute(
      [:statifier, :session, :macrostep, :start],
      %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
      %{session_id: session_id, trigger: :event, event_name: "go", span_ref: span_ref}
    )

    for event_name <- span_event_names() do
      :telemetry.execute(event_name, %{}, %{session_id: session_id})
    end

    :telemetry.execute(
      [:statifier, :session, :macrostep, :stop],
      %{duration: 500, monotonic_time: System.monotonic_time()},
      %{session_id: session_id, trigger: :event, outcome: :quiescent, span_ref: span_ref}
    )

    assert_receive {:span, captured}

    emitted =
      captured
      |> span(:events)
      |> SpanCapture.events()
      |> Enum.map(&event(&1, :name))
      |> MapSet.new()

    expected = span_event_names() |> Enum.map(&expected_span_event_name/1) |> MapSet.new()

    assert MapSet.difference(expected, emitted) == MapSet.new(),
           "these telemetry events reached the handler's catch-all instead of a mapping clause"

    assert MapSet.difference(emitted, expected) == MapSet.new(),
           "these span events were emitted under a name no telemetry event maps to"
  end

  # sabotage: @not_span_events pruned to the macrostep pair -> red, since
  # :init and :terminate then appear in span_event_names/0 and emit nothing
  test "the four unmapped names are still the ones the design excludes" do
    for event_name <- @not_span_events do
      assert event_name in Telemetry.events(),
             "#{inspect(event_name)} is no longer in the telemetry contract"
    end
  end
end
