defmodule OpentelemetryStatifier.Sibling do
  @moduledoc """
  The span mechanics the two sibling families share, so
  `OpentelemetryStatifier.Persistence.Handler` and
  `OpentelemetryStatifier.Oban.Handler` decide only what their own
  contracts decide - which event is an interval, which is a point, and
  where a point belongs - and nothing about how a span is opened.

  Three shapes cover both contracts (ADR-0004):

    * **A paired span**, opened on a `:start` and closed on the `:stop`
      whose `span_ref` matches. Only `statifier_persistence`'s step seam
      has one; `sob-ADR-0006` decided against pairs on the grounds that
      Oban already owns every interval it could bracket.
    * **An interval span**, for a point-in-time event that nonetheless
      carries a `duration` measurement (`[:statifier_persistence,
      :adapter, :call]` and `[..., :run, :lock]`). Its start is
      back-calculated as `now - duration`, the contrib family's usual
      shape, because the event reports an interval that has already
      closed.
    * **A point**, for everything else. It lands as a span event on the
      bridge span open around it when there is one, and becomes its own
      zero-duration span when there is not - a timer firing on an Oban
      worker days later has nothing of this bridge's open around it, and
      dropping it would lose the single most useful fact in the
      `statifier_oban` contract.

  **Nesting is through this bridge's own table, never the process's
  ambient OTel context.** `ADR-0003` decision 8's rule that the bridge
  neither reads nor writes the ambient context is unchanged; what
  ADR-0004 adds is that a span *this bridge itself* has open in *this
  process* parents the spans that follow it. That is what produces the
  topology `statifier_persistence`'s `docs/telemetry.md` describes -
  adapter call inside step, durable macrostep inside step - without the
  bridge ever touching a host's context.
  """

  require OpenTelemetry.Tracer

  alias OpentelemetryStatifier.{Attributes, Config, SiblingEntry, SpanEntry, SpanTable}

  @typedoc """
  Where a point event looks for a span to land on: the calling process's
  innermost open sibling span, or a logical session's innermost open
  macrostep span - the latter only when that session's macrostep is open
  in this very process, so a delivery-seam event on an Oban worker never
  writes onto a span another process holds for the same scope.

  `:detached` asks for neither: it is the shape for an event this bridge
  knows is running somewhere it has nothing open - inside an Oban job,
  days after the macrostep that armed it - where the span it becomes is
  a root linked to the arming trace rather than a child of anything.
  """
  @type host :: {:process, pid()} | {:session, String.t() | nil} | :detached

  @doc """
  Opens a paired span named `name` under `span_ref`, starting at
  `start_time`, nested in whatever sibling span is open in `pid`.
  """
  @spec open_span(Config.t(), String.t(), reference(), pid(), integer(), map()) :: :ok
  def open_span(%Config{table: table}, name, span_ref, pid, start_time, attributes) do
    ctx = parent_ctx(table, pid)

    span_ctx =
      OpenTelemetry.Tracer.start_span(ctx, name, %{
        start_time: start_time,
        attributes: attributes
      })

    SpanTable.put_sibling_span(table, span_ref, pid, %SiblingEntry{
      span_ctx: span_ctx,
      ctx: OpenTelemetry.Tracer.set_current_span(ctx, span_ctx),
      started_at: start_time
    })
  end

  @doc """
  Closes the paired span under `span_ref`, setting `attributes` first.
  A `span_ref` with no open span is contract-legal (the sweep ends the
  orphans a dead process leaves) and closes nothing.
  """
  @spec close_span(Config.t(), reference(), integer(), map()) :: :ok
  def close_span(%Config{table: table}, span_ref, end_time, attributes) do
    case SpanTable.take_sibling_span(table, span_ref) do
      {:ok, %SiblingEntry{span_ctx: span_ctx}} ->
        OpenTelemetry.Span.set_attributes(span_ctx, attributes)
        OpenTelemetry.Span.end_span(span_ctx, end_time)
        :ok

      :error ->
        :ok
    end
  end

  @doc """
  Records an already-closed interval of `duration` native time units as
  its own span named `name`, nested in whatever sibling span is open in
  the calling process.
  """
  @spec interval_span(Config.t(), String.t(), integer(), map()) :: :ok
  def interval_span(%Config{table: table}, name, duration, attributes) do
    now = System.monotonic_time()

    span_ctx =
      OpenTelemetry.Tracer.start_span(parent_ctx(table, self()), name, %{
        start_time: now - duration,
        attributes: attributes
      })

    OpenTelemetry.Span.end_span(span_ctx, now)
    :ok
  end

  @doc """
  Records a point-in-time event named `name`: a span event on the bridge
  span `host` names when one is open, and its own zero-duration span
  linked to `links` when none is.
  """
  @spec point(Config.t(), String.t(), host(), map(), [OpenTelemetry.link()]) :: :ok
  def point(%Config{table: table} = config, name, host, attributes, links) do
    case open_host_span(table, host) do
      {:ok, span_ctx} ->
        OpenTelemetry.Span.add_event(span_ctx, name, attributes)
        :ok

      :error ->
        detached_span(config, name, attributes, links)
    end
  end

  @doc """
  The link a `caller_context` yields, or `[]`.

  `st-ADR-0063` makes the slot an opaque host term and both sibling
  contracts carry it without reading it; the OTel-shaped reading of it
  lives here and nowhere else. A host that stamped the W3C text form -
  `%{"traceparent" => "00-<trace>-<span>-<flags>"}`, the form
  `statifier_oban`'s `docs/telemetry.md` tells hosts to write because the
  row outlives the node - links to the trace that armed the timer. Any
  other shape links to nothing: `nil` is the ordinary detached case, and
  a term this bridge cannot read is not an error either. The link is
  never a parent - parenthood would hold the arming trace open for the
  length of the delay.
  """
  @spec caller_context_links(term()) :: [OpenTelemetry.link()]
  def caller_context_links(%{"traceparent" => traceparent}) when is_binary(traceparent) do
    case remote_span_ctx(traceparent) do
      {:ok, span_ctx} -> [OpenTelemetry.link(span_ctx)]
      :error -> []
    end
  end

  def caller_context_links(_caller_context), do: []

  @doc """
  The attribute mapping for one sibling family: `prefix` as the
  namespace, and `correlation_key` (`session_id` here, `scope` there)
  aliased onto the shared `statifier.session_id` - the one attribute
  that joins a step, a timer and a macrostep across all three families.

  `monotonic_time` and `system_time` are dropped: they are the clock
  plumbing every family's events carry so a bridge can place a span, and
  the span's own start and end timestamps are where they land. `duration`
  is kept, because the sibling contracts publish it as a number a host
  reads without any tracing at all.
  """
  @spec mapping(String.t(), atom()) :: Attributes.mapping()
  def mapping(prefix, correlation_key) do
    base = Attributes.mapping(prefix, %{correlation_key => "statifier.session_id"})

    %{base | drop: base.drop ++ [:monotonic_time, :system_time]}
  end

  @doc """
  The span (or span-event) name for an event: its segments joined with
  dots, so span-name cardinality is exactly one per event name.
  """
  @spec name([atom()]) :: String.t()
  def name(event) when is_list(event), do: Enum.map_join(event, ".", &Atom.to_string/1)

  @spec open_host_span(atom(), host()) :: {:ok, OpenTelemetry.span_ctx()} | :error
  defp open_host_span(_table, :detached), do: :error

  defp open_host_span(table, {:process, pid}) do
    with {:ok, %SiblingEntry{span_ctx: span_ctx}} <-
           SpanTable.fetch_innermost_sibling_span(table, pid) do
      {:ok, span_ctx}
    end
  end

  defp open_host_span(table, {:session, session_id}) when is_binary(session_id) do
    # The pid check is the whole point: a session's macrostep span is
    # open in the session's own process, and a sibling event fired
    # anywhere else - an Oban worker, another node's driver - must not
    # write onto it.
    case SpanTable.fetch_session_pid(table, session_id) do
      {:ok, pid} when pid == self() -> innermost_session_span(table, session_id)
      _other -> :error
    end
  end

  defp open_host_span(_table, {:session, _session_id}), do: :error

  @spec innermost_session_span(atom(), String.t()) :: {:ok, OpenTelemetry.span_ctx()} | :error
  defp innermost_session_span(table, session_id) do
    case SpanTable.fetch_innermost_open_span(table, session_id) do
      {:ok, %SpanEntry{span_ctx: span_ctx}} -> {:ok, span_ctx}
      :error -> :error
    end
  end

  @spec detached_span(Config.t(), String.t(), map(), [OpenTelemetry.link()]) :: :ok
  defp detached_span(%Config{}, name, attributes, links) do
    now = System.monotonic_time()

    span_ctx =
      OpenTelemetry.Tracer.start_span(OpenTelemetry.Ctx.new(), name, %{
        start_time: now,
        attributes: attributes,
        links: links
      })

    OpenTelemetry.Span.end_span(span_ctx, now)
    :ok
  end

  @doc """
  The context a span opened in `pid` right now should start from: the
  innermost sibling span this bridge has open in that process, or an
  empty context when it has none.

  This is the whole of ADR-0004's nesting mechanism, and it is why the
  bridge still never reads the process's ambient OTel context: the only
  span that can parent another here is one this bridge itself opened, in
  this process, and recorded in its own table.
  """
  @spec parent_ctx(atom(), pid()) :: OpenTelemetry.Ctx.t()
  def parent_ctx(table, pid) do
    case SpanTable.fetch_innermost_sibling_span(table, pid) do
      {:ok, %SiblingEntry{ctx: ctx}} -> ctx
      :error -> OpenTelemetry.Ctx.new()
    end
  end

  # Parsed by hand rather than through a propagator: every propagator API
  # extracts *into* a context, and this bridge attaches nothing to the
  # process context. The version prefix is matched loosely on purpose -
  # the W3C spec says a future version's first three characters still
  # carry a parseable trace id and span id.
  @spec remote_span_ctx(String.t()) :: {:ok, OpenTelemetry.span_ctx()} | :error
  defp remote_span_ctx(
         <<_version::binary-size(2), "-", trace_id::binary-size(32), "-",
           span_id::binary-size(16), "-", flags::binary-size(2), _rest::binary>>
       ) do
    with {:ok, trace_id} <- parse_hex(trace_id),
         {:ok, span_id} <- parse_hex(span_id),
         {:ok, flags} <- parse_hex(flags),
         true <- trace_id != 0 and span_id != 0 do
      {:ok, :otel_tracer.from_remote_span(trace_id, span_id, flags)}
    else
      _invalid -> :error
    end
  end

  defp remote_span_ctx(_traceparent), do: :error

  @spec parse_hex(String.t()) :: {:ok, non_neg_integer()} | :error
  defp parse_hex(hex) do
    case Integer.parse(hex, 16) do
      {value, ""} -> {:ok, value}
      _other -> :error
    end
  end
end
