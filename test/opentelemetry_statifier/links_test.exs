defmodule OpentelemetryStatifier.LinksTest do
  # Global state twice over: `:telemetry`'s handler registry, and the
  # `:otel_simple_processor` exporter SpanCapture points at the test
  # process.
  use ExUnit.Case, async: false

  import OpentelemetryStatifier.SpanCapture

  alias OpentelemetryStatifier.SpanCapture
  alias OpentelemetryStatifier.SpanTable

  setup context do
    SpanCapture.start(context)

    table = :"links_test_#{System.unique_integer([:positive])}"
    SpanTable.new_table(table)
    :ok = OpentelemetryStatifier.setup(table: table)

    %{table: table}
  end

  defp emit_start(session_id, trigger, span_ref) do
    :telemetry.execute(
      [:statifier, :session, :macrostep, :start],
      %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
      %{session_id: session_id, trigger: trigger, event_name: nil, span_ref: span_ref}
    )
  end

  defp emit_stop(session_id, trigger, span_ref) do
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
        trigger: trigger,
        outcome: :quiescent,
        event_name: nil,
        configuration: MapSet.new(),
        span_ref: span_ref
      }
    )
  end

  defp emit_init(session_id, invoked_by) do
    :telemetry.execute(
      [:statifier, :session, :init],
      %{system_time: System.system_time()},
      %{
        session_id: session_id,
        machine_name: "chart",
        trace: false,
        invoked_by: invoked_by,
        resumed: false
      }
    )
  end

  defp span_links(captured) do
    captured
    |> span(:links)
    |> SpanCapture.links()
    |> Enum.map(fn l -> {link(l, :trace_id), link(l, :span_id)} end)
  end

  # sabotage: previous_macrostep_link/2's {:ok, ...} branch returns [] -> red
  test "a session's second macrostep links to its first" do
    span_ref_1 = make_ref()
    span_ref_2 = make_ref()

    emit_start("session-l1", :event, span_ref_1)
    emit_stop("session-l1", :event, span_ref_1)
    emit_start("session-l1", :event, span_ref_2)
    emit_stop("session-l1", :event, span_ref_2)

    assert_receive {:span, first}
    assert_receive {:span, second}

    assert span_links(first) == []
    assert span_links(second) == [{span(first, :trace_id), span(first, :span_id)}]

    # Links, not parenthood: the second span is still the root of its own
    # distinct trace.
    assert span(second, :parent_span_id) == :undefined
    assert span(second, :trace_id) != span(first, :trace_id)
  end

  # sabotage: the handler's :init clause stores the parked context under
  # parent_session_id instead of the child's session_id -> red (the child's
  # :initialize start finds nothing to link)
  test "a child session's :initialize macrostep links to the invoking parent's open span",
       %{table: table} do
    parent_ref = make_ref()
    child_ref = make_ref()

    emit_start("parent", :event, parent_ref)
    emit_init("child", {self(), "parent"})
    emit_start("child", :initialize, child_ref)
    emit_stop("child", :initialize, child_ref)
    emit_stop("parent", :event, parent_ref)

    assert_receive {:span, child_span}
    assert_receive {:span, parent_span}

    assert span_links(child_span) == [{span(parent_span, :trace_id), span(parent_span, :span_id)}]

    # Consumed on use: the parked row is gone once the link is attached.
    assert :error = SpanTable.take_invoke_parent(table, "child")
  end

  # sabotage: the :init clause resolves the parent through
  # `SpanTable.fetch_last_span_ctx/2` instead of
  # `SpanTable.fetch_innermost_open_span/2` -> red (the parent's already
  # closed macrostep would be linked; the contract is the span open when
  # the child started, or nothing)
  test "an :init whose parent has no open span stores nothing and links nothing" do
    parent_ref = make_ref()
    child_ref = make_ref()

    # The parent's only macrostep is already closed by the time the child
    # initializes.
    emit_start("parent-2", :event, parent_ref)
    emit_stop("parent-2", :event, parent_ref)
    assert_receive {:span, _parent_span}

    emit_init("child-2", {self(), "parent-2"})
    emit_start("child-2", :initialize, child_ref)
    emit_stop("child-2", :initialize, child_ref)

    assert_receive {:span, child_span}
    assert span_links(child_span) == []
  end

  # sabotage: the :init clause's head binds invoked_by as a plain variable
  # (accepting nil) and the fetch below uses `elem(invoked_by, 1)` -> red:
  # the handler raises on nil, :telemetry detaches it, and the
  # attached-handler assertion fails
  test "an :init with invoked_by: nil is ignored and the handler stays attached" do
    child_ref = make_ref()

    emit_init("child-3", nil)
    emit_start("child-3", :initialize, child_ref)
    emit_stop("child-3", :initialize, child_ref)

    assert_receive {:span, child_span}
    assert span_links(child_span) == []

    assert {OpentelemetryStatifier, [:statifier, :session, :init]} in handler_ids()
  end

  # sabotage: invoke_parent_link/3's non-:initialize clause is removed and
  # the :initialize clause made trigger-agnostic -> red (the parked link
  # would attach to this :event macrostep too)
  test "the invoke-parent link attaches only to an :initialize macrostep", %{table: table} do
    parent_ref = make_ref()
    child_ref = make_ref()

    emit_start("parent-4", :event, parent_ref)
    emit_init("child-4", {self(), "parent-4"})

    # The child's first macrostep arrives as :event (contract-illegal in
    # practice, but the bridge is defensive): the parked parent row must
    # survive untouched, and no invoke-parent link may attach.
    emit_start("child-4", :event, child_ref)
    emit_stop("child-4", :event, child_ref)
    emit_stop("parent-4", :event, parent_ref)

    assert_receive {:span, child_span}
    assert_receive {:span, _parent_span}

    assert span_links(child_span) == []
    assert {:ok, _parked} = SpanTable.take_invoke_parent(table, "child-4")
  end

  defp handler_ids do
    :telemetry.list_handlers([:statifier])
    |> Enum.map(& &1.id)
  end
end
