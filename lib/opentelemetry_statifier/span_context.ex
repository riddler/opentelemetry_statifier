defmodule OpentelemetryStatifier.SpanContext do
  @moduledoc """
  The bridge's keyed `(session_id, macrostep)` span-context read: the
  public lookup a wire-format producer needs to stamp OTel correlation
  ids onto the messages it emits.

  ## Why it exists

  `statifier_ui`'s trace wire format (its ADR-0013) reserves an optional
  `otel` envelope key carrying the W3C trace and span ids of the
  `statifier.macrostep` span a message belongs to, and specifies the seam
  that fills it as a host-supplied function:

      otel_context: (session_id, macrostep ->
                       {:ok, %{trace_id: binary, span_id: binary}} | :none)

  That record's arguments are `(session_id, macrostep)` and not "the
  currently open span" on purpose: the subscriber stamping the message is
  its own process consuming asynchronously, so "current" would silently
  stamp the wrong macrostep under lag. The same record names the lookup
  as an open dependency on this package, and this module is the answer -
  `lookup/2` has exactly that arity and exactly that return shape, so a
  host wires the two together by passing the capture and nothing else:

      StatifierUI.Trace.Subscriber.start_link(
        session: session,
        otel_context: &OpentelemetryStatifier.SpanContext.lookup/2
      )

  (The subscriber's `:otel_context` option is `statifier_ui`'s own
  follow-up to that record; this side of the seam is ready for it.)

  ## What it reads

  The bridge already holds every open macrostep span in the ETS table
  `OpentelemetryStatifier.SpanTable` owns, for its own link stitching.
  This is a read of that table and nothing more: no OTel context is
  created, entered, or attached, so ADR-0003 decision 8 - a macrostep
  span never starts from and is never attached to the process's ambient
  context - is untouched, and calling `lookup/2` from any process is
  safe.

  The macrostep counter a span covers is stamped onto its row by
  `OpentelemetryStatifier.Handler` from the first intra-macrostep event
  that lands on it, because statifier's macrostep `:start` event carries
  no such measurement. Every message the wire format may stamp is
  produced by one of those events, so a macrostep with a message to
  correlate always has its counter recorded.

  ## When it answers `:none`

  `:none` is an ordinary answer, not an error, and it is what the wire
  format degrades to (the key is simply absent). It is returned when the
  bridge was never set up, when `session_id` is unknown, when the
  macrostep's span has already closed - a subscriber lagging behind the
  session process is the common case - and when the span context on the
  row carries no valid ids. Consumers never see half a pair: ADR-0013
  requires both ids or neither, and this module returns both or `:none`.
  """

  alias OpentelemetryStatifier.SpanTable

  @typedoc """
  The lowercase hex W3C Trace Context ids of one `statifier.macrostep`
  span: `trace_id` is exactly 32 hex digits, `span_id` exactly 16, with
  no `0x` prefix, no dashes, and no uppercase.
  """
  @type t :: %{trace_id: String.t(), span_id: String.t()}

  @default_table OpentelemetryStatifier.SpanTable

  @doc """
  Looks up the open `statifier.macrostep` span covering `macrostep` in
  `session_id`, against the bridge's default span table.

  Returns `{:ok, %{trace_id: hex, span_id: hex}}` on a hit and `:none` on
  a miss. This is the function to hand a `statifier_ui` subscriber as its
  `:otel_context` producer.

  ## Examples

      iex> OpentelemetryStatifier.SpanContext.lookup("no-such-session", 1)
      :none

  """
  @spec lookup(String.t(), non_neg_integer()) :: {:ok, t()} | :none
  def lookup(session_id, macrostep), do: lookup(session_id, macrostep, @default_table)

  @doc """
  As `lookup/2`, against the span table named by `table`.

  Hosts that passed `:table` to `OpentelemetryStatifier.setup/1` build
  their producer from this arity - `&SpanContext.lookup(&1, &2, :my_table)`
  is still the 2-arity function ADR-0013 asks for.
  """
  @spec lookup(String.t(), non_neg_integer(), atom()) :: {:ok, t()} | :none
  def lookup(session_id, macrostep, table)
      when is_binary(session_id) and is_integer(macrostep) and macrostep >= 0 and
             is_atom(table) and not is_nil(table) do
    if :ets.whereis(table) == :undefined do
      :none
    else
      fetch(table, session_id, macrostep)
    end
  end

  def lookup(_session_id, _macrostep, _table), do: :none

  @spec fetch(atom(), String.t(), non_neg_integer()) :: {:ok, t()} | :none
  defp fetch(table, session_id, macrostep) do
    case SpanTable.fetch_open_span_ctx(table, session_id, macrostep) do
      {:ok, span_ctx} -> hex_pair(span_ctx)
      :error -> :none
    end
  end

  # The SDK caches hex forms on the span_ctx record, but only on the paths
  # that happen to populate them - `undefined` is a legal value of both
  # fields - so the encoding is derived from the integer ids here rather
  # than read off the record. All-zero ids are OTel's invalid trace and
  # span, and a correlation key pointing at them is unusable in every
  # backend, so they are a miss.
  @spec hex_pair(OpenTelemetry.span_ctx()) :: {:ok, t()} | :none
  defp hex_pair(span_ctx) do
    trace_id = OpenTelemetry.Span.trace_id(span_ctx)
    span_id = OpenTelemetry.Span.span_id(span_ctx)

    if trace_id == 0 or span_id == 0 do
      :none
    else
      {:ok, %{trace_id: hex(trace_id, 32), span_id: hex(span_id, 16)}}
    end
  end

  @spec hex(non_neg_integer(), pos_integer()) :: String.t()
  defp hex(id, digits) do
    id
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(digits, "0")
  end
end
