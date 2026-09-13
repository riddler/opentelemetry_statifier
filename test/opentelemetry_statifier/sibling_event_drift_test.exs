defmodule OpentelemetryStatifier.SiblingEventDriftTest do
  # Pure list comparison against two modules that are loaded, never
  # started: the sibling packages are `only: :test, runtime: false`.
  use ExUnit.Case, async: true

  alias OpentelemetryStatifier.{Oban, Persistence}

  # The literal lists in `OpentelemetryStatifier.Persistence` and
  # `OpentelemetryStatifier.Oban` exist because this package must not make
  # `statifier_persistence` (and Ecto, and a database driver) or
  # `statifier_oban` (and Oban) a dependency of every host that wants
  # statechart tracing - st-ADR-0062's family-scope clause and ots-ADR-0004.
  # Test-only deps buy the check back without buying the coupling: a name
  # added, removed, or renamed upstream fails this gate instead of going
  # silently unbridged at the next sibling release.
  #
  # Order is not part of the contract - the assertions compare sorted lists
  # so an upstream reordering is not a false red - but membership and count
  # are, and the count is asserted separately so a *pair* of compensating
  # edits still cannot slip through as "same length, same names".

  describe "statifier_persistence" do
    # sabotage: `[:statifier_persistence, :child, :answered]` renamed to
    # `:replied` in Persistence's @events -> red
    test "the bridged list is exactly StatifierPersistence.Telemetry.events/0" do
      assert Enum.sort(Persistence.events()) ==
               Enum.sort(StatifierPersistence.Telemetry.events())
    end

    # sabotage: a sixteenth name deleted from Persistence's @events -> red
    test "the bridged list carries the contract's 16 names" do
      assert length(Persistence.events()) == 16
      assert length(StatifierPersistence.Telemetry.events()) == 16
    end

    # The retired durable noun. sp-ADR-0011 moved this family to the
    # `:execution` prefix with no dual emit, so a `:run` segment left in
    # the attach list is a handler bound to a name nothing emits.
    #
    # A one-sided edit here is caught by the comparison above, which is
    # the ordinary case. What this asserts on top of it is the direction
    # of the agreement: the comparison passes whenever the two sides
    # match, so walking the pin backwards to a release that still spells
    # the old noun leaves it green while the bridge silently returns to
    # the retired vocabulary. Naming the retired segment directly is what
    # survives a pin regression.
    #
    # sabotage: `[:statifier_persistence, :execution, :lock]` put back as
    # `[:statifier_persistence, :run, :lock]` -> red
    test "no subscription carries the retired :run segment" do
      assert Enum.all?(Persistence.events(), &(:run not in &1))
    end
  end

  describe "statifier_oban" do
    # sabotage: `[:statifier_oban, :invoke, :delivered]` renamed to
    # `:answered` in Oban's @events -> red
    test "the bridged list is exactly StatifierOban.Telemetry.events/0" do
      assert Enum.sort(Oban.events()) == Enum.sort(StatifierOban.Telemetry.events())
    end

    # sabotage: a fourteenth name deleted from Oban's @events -> red
    test "the bridged list carries the contract's 14 names" do
      assert length(Oban.events()) == 14
      assert length(StatifierOban.Telemetry.events()) == 14
    end

    # sabotage: `[:statifier_oban, :invoke, :child_started]` deleted from
    # Oban's @events -> red
    test "the fan-out seam's three kinds are bridged" do
      kinds = for [:statifier_oban, :invoke, kind] <- Oban.events(), do: kind

      assert :fan_out in kinds
      assert :child_started in kinds
      assert :unstarted_cancelled in kinds
    end
  end
end
