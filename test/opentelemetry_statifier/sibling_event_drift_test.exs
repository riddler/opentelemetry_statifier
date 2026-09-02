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

    # sabotage: a fourteenth name deleted from Persistence's @events -> red
    test "the bridged list carries the contract's 14 names" do
      assert length(Persistence.events()) == 14
      assert length(StatifierPersistence.Telemetry.events()) == 14
    end
  end

  describe "statifier_oban" do
    # sabotage: `[:statifier_oban, :invoke, :delivered]` renamed to
    # `:answered` in Oban's @events -> red
    test "the bridged list is exactly StatifierOban.Telemetry.events/0" do
      assert Enum.sort(Oban.events()) == Enum.sort(StatifierOban.Telemetry.events())
    end

    # sabotage: an eleventh name deleted from Oban's @events -> red
    test "the bridged list carries the contract's 11 names" do
      assert length(Oban.events()) == 11
      assert length(StatifierOban.Telemetry.events()) == 11
    end
  end
end
