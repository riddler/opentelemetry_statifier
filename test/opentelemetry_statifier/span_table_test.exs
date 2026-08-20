defmodule OpentelemetryStatifier.SpanTableTest do
  use ExUnit.Case, async: true

  alias OpentelemetryStatifier.SpanEntry
  alias OpentelemetryStatifier.SpanTable

  defp unique_table(tag) do
    name = :"span_table_test_#{tag}_#{System.unique_integer([:positive])}"
    SpanTable.new_table(name)
    name
  end

  # A span_ctx() is an opaque record as far as SpanTable is concerned - it
  # is only ever stored and returned, never inspected - so a unique term
  # stands in for a real one here and lets each assertion tell contexts
  # apart without depending on the SDK's tracer plumbing.
  defp fake_span_ctx, do: make_ref()

  defp entry(session_id) do
    %SpanEntry{
      session_id: session_id,
      span_ctx: fake_span_ctx(),
      trigger: :start,
      started_at: System.monotonic_time()
    }
  end

  # sabotage: take_open_span/2 changed to leave the row in place after a hit
  # (drop the :ets.delete/2 call) -> red
  test "put then take round-trips an entry, and a second take on the same ref is :error" do
    table = unique_table(:round_trip)
    span_ref = make_ref()
    entry = entry("session-1")

    assert :ok = SpanTable.put_open_span(table, span_ref, entry)
    assert {:ok, ^entry} = SpanTable.take_open_span(table, span_ref)
    assert :error = SpanTable.take_open_span(table, span_ref)
  end

  # sabotage: put_open_span/3 hardcodes the row key to {:span, :fixed} instead
  # of {:span, span_ref} -> red
  test "two entries for one session under different span_refs coexist and are taken independently" do
    table = unique_table(:reentry)
    ref_a = make_ref()
    ref_b = make_ref()
    entry_a = entry("session-2")
    entry_b = entry("session-2")

    assert :ok = SpanTable.put_open_span(table, ref_a, entry_a)
    assert :ok = SpanTable.put_open_span(table, ref_b, entry_b)

    assert {:ok, ^entry_a} = SpanTable.take_open_span(table, ref_a)
    assert {:ok, ^entry_b} = SpanTable.take_open_span(table, ref_b)
    assert :error = SpanTable.take_open_span(table, ref_a)
    assert :error = SpanTable.take_open_span(table, ref_b)
  end

  # sabotage: fetch_last_span_ctx/2 changed to return {:ok, nil} instead of
  # :error on a miss -> red
  test "fetch_last_span_ctx/2 is :error for an unknown session and the last value for a known one" do
    table = unique_table(:last_span_ctx)
    session_id = "session-3"

    assert :error = SpanTable.fetch_last_span_ctx(table, session_id)

    ctx_1 = fake_span_ctx()
    ctx_2 = fake_span_ctx()

    assert :ok = SpanTable.put_last_span_ctx(table, session_id, ctx_1)
    assert :ok = SpanTable.put_last_span_ctx(table, session_id, ctx_2)

    assert {:ok, ^ctx_2} = SpanTable.fetch_last_span_ctx(table, session_id)
  end

  # sabotage: put_open_span/3 hardcodes the row key to {:span, :fixed} instead
  # of {:span, span_ref} (same mutation as the re-entry test above, observed
  # here through match_object instead of take_open_span) -> red
  test "the row shape matches what a sweeper needs: match_object finds both row kinds for a session" do
    table = unique_table(:match_object)
    session_id = "session-4"
    span_ref = make_ref()

    assert :ok = SpanTable.put_open_span(table, span_ref, entry(session_id))

    ctx = fake_span_ctx()
    assert :ok = SpanTable.put_last_span_ctx(table, session_id, ctx)

    rows = :ets.match_object(table, {:_, session_id, :_})

    assert length(rows) == 2
    assert Enum.any?(rows, &match?({{:span, ^span_ref}, ^session_id, %SpanEntry{}}, &1))
    assert Enum.any?(rows, &match?({{:last_span_ctx, ^session_id}, ^session_id, ^ctx}, &1))
  end

  # sabotage: OpentelemetryStatifier.Application's children list emptied to
  # [] so SpanTable never starts under the OTP application -> red
  test "the application-started table exists and is named without calling setup/1" do
    assert :ets.info(OpentelemetryStatifier.SpanTable) != :undefined
    assert :ets.info(OpentelemetryStatifier.SpanTable, :named_table) == true
  end
end
