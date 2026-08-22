defmodule OpentelemetryStatifier.SpanCapture do
  @moduledoc """
  Test-only in-process span capture: Flavor A of the family's two testing
  shapes (see the plan's Phase 3), built entirely on the `opentelemetry`
  SDK's own test exporter rather than anything this package invents.

  `:otel_exporter_pid` (`deps/opentelemetry/src/otel_exporter_pid.erl`)
  sends every ended span to a pid as `{:span, span}` once
  `:otel_simple_processor` (configured in `config/test.exs`) exports it -
  synchronously, so a test can `assert_receive {:span, span(...)}`
  immediately after the code under test returns, with no polling.

  The `span(...)` record macros below come from the SDK's own
  `otel_span.hrl`, extracted at compile time rather than hand-copied, so a
  field addition upstream shows up here for free. Only `test/support/` -
  excluded from the coverage floor - ever requires the `opentelemetry` SDK;
  `lib/` depends on `opentelemetry_api` alone.
  """

  require Record

  for {name, spec} <- Record.extract_all(from_lib: "opentelemetry/include/otel_span.hrl") do
    Record.defrecord(name, spec)
  end

  @doc """
  Points the globally configured `:otel_simple_processor` exporter at the
  calling test process for the duration of the current test, and tears
  down anything the test attached to `OpentelemetryStatifier` on exit.

  Call from a test's `setup` block. Tests remain `async: false`: both the
  `:telemetry` handler registry and this exporter are process-global.
  """
  @spec start(ExUnit.Callbacks.context()) :: :ok
  def start(_context) do
    :ok = :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    ExUnit.Callbacks.on_exit(fn -> OpentelemetryStatifier.teardown() end)
    :ok
  end

  @doc """
  Converts a captured span's `otel_attributes:t()` field into a plain map
  for assertions.
  """
  @spec attributes(term()) :: map()
  def attributes(attrs), do: :otel_attributes.map(attrs)

  @doc """
  Converts a captured span's `otel_events:t()` field into the plain list
  of `event(...)` records it holds.
  """
  @spec events(term()) :: [term()]
  def events(events), do: :otel_events.list(events)

  @doc """
  Converts a captured span's `otel_links:t()` field into the plain list
  of `link(...)` records it holds.
  """
  @spec links(term()) :: [term()]
  def links(links), do: :otel_links.list(links)
end
