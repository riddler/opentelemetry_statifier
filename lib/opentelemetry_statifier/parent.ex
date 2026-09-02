defmodule OpentelemetryStatifier.Parent do
  @moduledoc """
  Declares the span that encloses a session's macrostep spans, for a
  durable driver this package knows nothing about.

  ## Why it exists

  A `statifier.macrostep` span is the root of its own trace, stitched to
  its neighbours with links (ADR-0003 decision 8). The one exception is
  the family's own durable stepper: with
  `OpentelemetryStatifier.Persistence` attached, a macrostep driven
  inside a `statifier_persistence.run.step` span nests inside it, so a
  durable run reads as one tree (ADR-0004 decision 4).

  That nesting was never really about `statifier_persistence`. It is
  about *a* durable stepper: a host with its own storage, its own lock
  and its own step span wants the same tree, and had no way to ask for
  it. This module is the way to ask. It generalises ADR-0004 decision 4
  from the family's durable stepper to any durable stepper, and nothing
  else about the bridge changes: a host that never calls `register/2`
  gets byte-identical behaviour, and the family's own persistence path
  is untouched whether this API is used or not.

  ## What it is not

  It is not a way to pick up the process's ambient OTel context. The
  bridge still never reads it, and still never attaches anything to it
  (ADR-0003 decision 8). A declaration is an **explicit hand-in**: the
  host names the span it means, and that is precisely what makes it safe
  where reading the ambient context would not be. A host with an
  unrelated HTTP request span open does not silently capture every
  macrostep into it; a host that wants its step span to be the parent
  says so.

  It is also not a way to write onto the declared span. The bridge
  parents spans under it and nothing more - no attributes, no span
  events, and no ending it. The span's lifetime stays entirely the
  host's.

  ## Using it

  The scoped form is the one to reach for: it withdraws the declaration
  on the way out, including when the block raises.

      require OpenTelemetry.Tracer

      OpenTelemetry.Tracer.with_span "my_app.workflow.step" do
        OpentelemetryStatifier.Parent.within(
          OpenTelemetry.Tracer.current_span_ctx(),
          fn ->
            # every statifier.macrostep span this process drives in here
            # nests inside my_app.workflow.step
            MyApp.DurableStepper.drive(session_id, event)
          end
        )
      end

  Use `register/2` and `unregister/1` directly when the enclosing span
  outlives one function call - a `GenServer` that opens a step span in
  one callback and closes it in another, say:

      {:ok, registration} = OpentelemetryStatifier.Parent.register(span_ctx)
      # ...
      :ok = OpentelemetryStatifier.Parent.unregister(registration)

  ## Which spans nest

  A declaration is keyed on the **process** whose spans nest under it,
  which defaults to `self()` - the shape a driver that steps the session
  synchronously in its own process wants. A driver that steps a session
  in another process passes `pid: session_pid`.

  Declarations compose with the bridge's own sibling spans and with each
  other: the innermost declaration or open sibling span at the moment a
  macrostep starts is its parent, so a host that runs both its own
  stepper and `statifier_persistence` gets the tree it would expect.

  ## When the registrant dies

  A registration is withdrawn by the process that made it. If that
  process dies without withdrawing - a driver crashing mid-step - the
  declaration is abandoned: nobody is left to end the declared span, so
  nesting under it would attach live spans to a trace that will never
  close. Macrostep spans fall back to rooting their own traces from the
  moment the registrant dies, and `OpentelemetryStatifier.SpanTable`'s
  sweep deletes the row without ending the declared span, because this
  bridge did not open it.

  A `register/2` that cannot record the declaration returns
  `{:error, reason}` rather than raising: `:invalid_span` for anything
  that is not a valid, non-zero span context (`:undefined` from a
  `current_span_ctx/0` with no span open is the common one),
  `:registrant_not_alive` for a `:pid` that is already gone, and
  `:no_span_table` when the bridge was never set up. Telemetry never
  breaks the host, so `within/3` runs its block either way and simply
  does not nest.
  """

  require OpenTelemetry.Tracer
  require Record

  alias OpentelemetryStatifier.{ParentEntry, SpanTable}

  # Extracted at compile time from the API's own header rather than
  # hand-copied, the way `OpentelemetryStatifier.SpanCapture` extracts the
  # SDK's span record: it pins the record's arity as well as its field
  # names, so a hand-built tuple that merely starts with `:span_ctx` is
  # refused rather than half-accepted.
  Record.defrecordp(
    :span_ctx,
    Record.extract(:span_ctx, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
  )

  @default_table OpentelemetryStatifier.SpanTable

  @typedoc """
  An opaque handle to one live declaration. Hand it to `unregister/1`;
  nothing else reads it.
  """
  @opaque registration :: {atom(), reference()}

  @typedoc """
  Why a declaration was refused. Every one of them is an ordinary answer
  the caller can act on, not an exception.
  """
  @type error ::
          :invalid_span
          | :registrant_not_alive
          | :no_span_table
          | {:unknown_options, [atom()]}

  @doc """
  Declares `span_ctx` as the enclosing span for the macrostep spans a
  process drives from now until `unregister/1`.

  Options:

    * `:pid` - the process whose spans nest under `span_ctx`. Defaults to
      `self()`, which is what a driver stepping the session in its own
      process wants.
    * `:table` - the span table, for a host that passed `:table` to
      `OpentelemetryStatifier.setup/1`. Defaults to
      `OpentelemetryStatifier.SpanTable`.

  Returns `{:ok, registration}`, or `{:error, reason}` - see the
  moduledoc's list; the caller is never left guessing whether the
  declaration took.

  ## Examples

      iex> OpentelemetryStatifier.Parent.register(:undefined)
      {:error, :invalid_span}

  """
  @spec register(OpenTelemetry.span_ctx(), keyword()) :: {:ok, registration()} | {:error, error()}
  def register(span_ctx, opts \\ []) do
    with {:ok, opts} <- validate_opts(opts),
         :ok <- validate_span_ctx(span_ctx),
         table = Keyword.get(opts, :table, @default_table),
         :ok <- validate_table(table) do
      pid = Keyword.get(opts, :pid, self())

      if Process.alive?(pid) do
        {:ok, insert(table, pid, span_ctx)}
      else
        {:error, :registrant_not_alive}
      end
    end
  end

  @doc """
  Withdraws the declaration `register/2` returned.

  Idempotent, and safe from any process: withdrawing a declaration that
  is already gone - swept after its registrant died, or withdrawn once
  already by an `after` block that ran twice - is `:ok`. The declared
  span is never ended here; the host that opened it owns its lifetime.
  """
  @spec unregister(registration()) :: :ok
  def unregister({table, ref}) when is_atom(table) and is_reference(ref) do
    if :ets.whereis(table) == :undefined do
      :ok
    else
      SpanTable.delete_parent_span(table, ref)
    end
  end

  @doc """
  Runs `fun` with `span_ctx` declared as the enclosing span, and
  withdraws the declaration afterwards - including when `fun` raises,
  throws, or exits.

  Returns whatever `fun` returns. A declaration that could not be
  recorded is **not** an error here: instrumentation does not decide
  whether a host's work runs, so `fun` is called either way and its
  macrostep spans simply root their own traces. Call `register/2`
  directly when you want to see the reason.

  Takes the same options as `register/2`.
  """
  @spec within(OpenTelemetry.span_ctx(), (-> result), keyword()) :: result when result: var
  def within(span_ctx, fun, opts \\ []) when is_function(fun, 0) do
    case register(span_ctx, opts) do
      {:ok, registration} ->
        try do
          fun.()
        after
          unregister(registration)
        end

      {:error, _reason} ->
        fun.()
    end
  end

  @spec insert(atom(), pid(), OpenTelemetry.span_ctx()) :: registration()
  defp insert(table, pid, span_ctx) do
    ref = make_ref()

    entry = %ParentEntry{
      span_ctx: span_ctx,
      # Built from a fresh context, never from the caller's ambient one:
      # the span was handed in, and reading `Ctx.get_current/0` here
      # would smuggle in whatever else the host had open (ADR-0003
      # decision 8).
      ctx: OpenTelemetry.Tracer.set_current_span(OpenTelemetry.Ctx.new(), span_ctx),
      registrant: self(),
      registered_at: System.monotonic_time()
    }

    SpanTable.put_parent_span(table, ref, pid, entry)
    {table, ref}
  end

  # Hand-validated, ADR-0003 decision 1's reasoning: three option keys do
  # not justify a runtime dependency, and an unknown key is an evaluation
  # that failed, not something to ignore.
  @spec validate_opts(keyword()) :: {:ok, keyword()} | {:error, error()}
  defp validate_opts(opts) when is_list(opts) do
    case Keyword.keys(opts) -- [:pid, :table] do
      [] -> {:ok, opts}
      unknown -> {:error, {:unknown_options, unknown}}
    end
  end

  # The tracer will happily open a child of a malformed context rather
  # than complain, so the shape is checked here. Zero ids are OTel's
  # invalid trace and span - `:undefined` from a `current_span_ctx/0`
  # with nothing open decodes to them - and nesting under one produces a
  # tree no backend can render.
  @spec validate_span_ctx(term()) :: :ok | {:error, error()}
  defp validate_span_ctx(span_ctx(trace_id: trace_id, span_id: span_id))
       when is_integer(trace_id) and trace_id > 0 and is_integer(span_id) and span_id > 0,
       do: :ok

  defp validate_span_ctx(_span_ctx), do: {:error, :invalid_span}

  @spec validate_table(atom()) :: :ok | {:error, error()}
  defp validate_table(table) when is_atom(table) and not is_nil(table) do
    if :ets.whereis(table) == :undefined, do: {:error, :no_span_table}, else: :ok
  end

  defp validate_table(_table), do: {:error, :no_span_table}
end
