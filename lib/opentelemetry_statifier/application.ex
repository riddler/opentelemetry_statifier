defmodule OpentelemetryStatifier.Application do
  @moduledoc """
  Starts `OpentelemetryStatifier.SpanTable` so the ETS table it owns
  exists before any handler `OpentelemetryStatifier.setup/1` attaches can
  fire, and survives every session process. This is the package's only
  supervised process; a host that never calls `setup/1` pays the cost of
  one idle process, the normal shape for instrumentation packages.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      OpentelemetryStatifier.SpanTable
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: OpentelemetryStatifier.Supervisor
    )
  end
end
