defmodule OpentelemetryStatifierTest do
  # :telemetry's handler registry is a global table, so tests that attach
  # and inspect handler ids cannot run concurrently with each other.
  use ExUnit.Case, async: false

  doctest OpentelemetryStatifier

  alias Statifier.Session.Telemetry

  setup do
    on_exit(&OpentelemetryStatifier.teardown/0)
  end

  defp handler_ids do
    :telemetry.list_handlers([:statifier])
    |> Enum.map(& &1.id)
  end

  # sabotage: setup/1's Enum.each attaches only Enum.take(Telemetry.events(), 5)
  # instead of the full list -> red
  test "setup/1 attaches a handler to every event Telemetry.events/0 names" do
    assert :ok = OpentelemetryStatifier.setup()

    ids = handler_ids()

    for event <- Telemetry.events() do
      assert {OpentelemetryStatifier, ^event} =
               Enum.find(ids, &match?({OpentelemetryStatifier, ^event}, &1))
    end

    assert length(ids) == length(Telemetry.events())
  end

  # sabotage: setup/1 skips the teardown() call before re-attaching -> red
  # (without detaching first, the second attach for each id silently fails
  # with {:error, :already_exists} - discarded by Enum.each - so the first
  # call's config, not the second's, would still be the one attached)
  test "setup/1 is idempotent: a second call replaces the first attachment" do
    assert :ok = OpentelemetryStatifier.setup()
    assert :ok = OpentelemetryStatifier.setup(table: :some_other_table)

    assert length(handler_ids()) == length(Telemetry.events())

    %{config: config} =
      Enum.find(
        :telemetry.list_handlers([:statifier]),
        &match?({OpentelemetryStatifier, [:statifier, :session, :init]}, &1.id)
      )

    assert %OpentelemetryStatifier.Config{table: :some_other_table} = config
  end

  # sabotage: setup/1 hardcodes record_datamodel_values: false into the
  # attached Config regardless of opts -> red
  test "setup/1 with record_datamodel_values: true carries it into the handler config" do
    assert :ok = OpentelemetryStatifier.setup(record_datamodel_values: true)

    %{config: config} =
      Enum.find(
        :telemetry.list_handlers([:statifier]),
        &match?({OpentelemetryStatifier, [:statifier, :session, :init]}, &1.id)
      )

    assert %OpentelemetryStatifier.Config{record_datamodel_values: true} = config
  end

  # sabotage: Config.new/1 ignores unknown keys instead of rejecting them -> red
  test "setup/1 with an unknown option key returns an error and attaches nothing" do
    assert {:error, {:unknown_options, [:bogus]}} = OpentelemetryStatifier.setup(bogus: true)
    assert handler_ids() == []
  end

  # sabotage: Config.new/1's boolean check for :record_datamodel_values is
  # dropped (any value accepted) -> red
  test "setup/1 with a non-boolean record_datamodel_values value returns an error" do
    assert {:error, {:invalid_option, :record_datamodel_values, "yes"}} =
             OpentelemetryStatifier.setup(record_datamodel_values: "yes")

    assert handler_ids() == []
  end

  # sabotage: teardown/0's Enum.each is replaced with a no-op -> red
  test "teardown/0 leaves no handlers attached" do
    assert :ok = OpentelemetryStatifier.setup()
    assert :ok = OpentelemetryStatifier.teardown()

    assert handler_ids() == []
  end

  # sabotage: Handler.handle_event/4's catch-all clause head narrowed to
  # require a `%{some_key: _}` measurements map -> red (telemetry detaches a
  # handler that raises on the unmatched empty map, so the assertion below -
  # the handler is still attached after a garbage event - is what fails)
  test "the handler survives an event with garbage measurements and metadata" do
    assert :ok = OpentelemetryStatifier.setup()

    :telemetry.execute([:statifier, :session, :trace, :done], %{}, %{})

    assert {OpentelemetryStatifier, [:statifier, :session, :trace, :done]} in handler_ids()
  end
end
