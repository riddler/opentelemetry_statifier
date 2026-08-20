defmodule OpentelemetryStatifierTest do
  use ExUnit.Case, async: true

  doctest OpentelemetryStatifier

  # sabotage: setup/0 returns :error -> red
  test "setup/0 is callable while the bridge is unimplemented" do
    assert :ok = OpentelemetryStatifier.setup()
  end
end
