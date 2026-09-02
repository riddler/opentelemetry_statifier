defmodule OpentelemetryStatifier.Persistence do
  @moduledoc """
  The bridge half for `statifier_persistence`'s own event family,
  `[:statifier_persistence, ...]` - the durable stepper's storage
  phases, frozen by that package's `docs/adr/0009-telemetry-events-for-the-durable-stepper.md`
  and tabulated in its `docs/telemetry.md`.

  It is a **separate setup call**, per st-ADR-0062 and `ots-ADR-0002`
  decision 2: a host that steps durably calls

      OpentelemetryStatifier.setup()
      OpentelemetryStatifier.Persistence.setup()

  the shape `opentelemetry_ecto` and `opentelemetry_oban` compose in.
  Nothing here attaches unless the host asks for it, and a host with no
  durable stepper pays nothing.

  ## What it produces

  `[:statifier_persistence, :run, :step, :start]` / `[..., :stop]` is the
  one paired seam the sibling contracts define, and it becomes a
  `statifier_persistence.run.step` span - the interval the durable
  stepper owns and nothing else measures: lock, load, decode,
  identity-check, advance, execute effects, persist. **The macrostep span
  for the step nests inside it**, as do the `statifier_persistence.adapter.call`
  and `statifier_persistence.run.lock` spans, so a durable run reads as
  one tree rather than as two unrelated families. The nesting runs
  through this bridge's own span table, not the process's ambient OTel
  context (`docs/adr/0004-sibling-setup-calls-and-bridge-owned-nesting.md`).

  Every other event in the family is a point: a span event on the step
  span open around it, or its own zero-duration span when there is none.

  ## What it does not do

  `statifier_persistence` also emits the *interpreter's* family with
  `driver: :persistence` (st-ADR-0067), and that needs no bridge work of
  its own - `OpentelemetryStatifier.setup/1` already attaches it, and the
  `driver` metadata maps to `statifier.driver` through the mapping the
  bridge already has. Attaching this module without that one produces
  step spans with nothing inside them.

  ## The event list

  The 14 names below are literal here rather than read from
  `StatifierPersistence.Telemetry.events/0`, because this package takes
  no dependency on its siblings: a bridge that made `statifier_persistence`
  (and through it Ecto, and a database driver) a dependency of every host
  that wants statechart tracing would have the dependency direction
  exactly backwards.

  The two lists are not checked by hand. `statifier_persistence` is a
  `only: :test, runtime: false` dependency of this package, and
  `test/opentelemetry_statifier/sibling_event_drift_test.exs` asserts this
  list against `StatifierPersistence.Telemetry.events/0` on every gate
  run, so a name added, removed, or renamed upstream turns this repo red
  rather than silently going unbridged. A host pays nothing for that: an
  `only: :test` dependency is not a published Hex requirement.
  """

  alias OpentelemetryStatifier.Config
  alias OpentelemetryStatifier.Persistence.Handler

  @events [
    [:statifier_persistence, :run, :step, :start],
    [:statifier_persistence, :run, :step, :stop],
    [:statifier_persistence, :run, :lock],
    [:statifier_persistence, :adapter, :call],
    [:statifier_persistence, :identity, :refused],
    [:statifier_persistence, :run, :created],
    [:statifier_persistence, :run, :terminated],
    [:statifier_persistence, :run, :discarded],
    [:statifier_persistence, :effect, :failed],
    [:statifier_persistence, :drive, :turns_exhausted],
    [:statifier_persistence, :child, :started],
    [:statifier_persistence, :child, :refused],
    [:statifier_persistence, :child, :answered],
    [:statifier_persistence, :child, :cascade_cancelled]
  ]

  @doc """
  The event names this module attaches to - `statifier_persistence`'s
  family two, in full.

  ## Examples

      iex> length(OpentelemetryStatifier.Persistence.events())
      14

  """
  @spec events() :: [:telemetry.event_name()]
  def events, do: @events

  @doc """
  Attaches this family with default options. Delegates to `setup/1`.

  ## Examples

      iex> OpentelemetryStatifier.Persistence.setup()
      :ok

  """
  @spec setup() :: :ok | {:error, term()}
  def setup, do: setup([])

  @doc """
  Validates `opts` into a `OpentelemetryStatifier.Config.t()` and attaches
  this module's handler to every name `events/0` returns, one
  `:telemetry.attach/4` call per name under a per-event handler id -
  ADR-0003 decision 2's discipline, so a raise while handling one event
  name costs that name and nothing else.

  Idempotent, exactly as `OpentelemetryStatifier.setup/1` is: the ids this
  module owns are detached before they are attached, so a second call
  replaces the first attachment. The two setups are independent - this one
  detaches and attaches nothing outside its own family.
  """
  @spec setup(keyword()) :: :ok | {:error, term()}
  def setup(opts) do
    with {:ok, config} <- Config.new(opts) do
      :ok = teardown()

      Enum.each(@events, fn event ->
        :telemetry.attach(handler_id(event), event, &Handler.handle_event/4, config)
      end)
    end
  end

  @doc """
  Detaches every handler id this module owns. Always returns `:ok`, even
  when nothing was attached.
  """
  @spec teardown() :: :ok
  def teardown do
    Enum.each(@events, &:telemetry.detach(handler_id(&1)))
  end

  defp handler_id(event), do: {__MODULE__, event}
end
