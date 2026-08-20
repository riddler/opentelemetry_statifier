defmodule OpentelemetryStatifier.Handler do
  @moduledoc """
  The `:telemetry` handler attached to every name
  `Statifier.Session.Telemetry.events/0` returns.

  There is deliberately no `try`/`rescue` here. `:telemetry` itself catches
  `error | exit | throw` from a raising handler and detaches it
  (`deps/telemetry/src/telemetry.erl:196-215`) - and because
  `OpentelemetryStatifier.setup/1` attaches one handler id per event name
  (rather than one `attach_many/4` id shared across all 27), a raise in one
  clause only costs that one event name, not the whole bridge, for the rest
  of the VM's life. The defensive posture this module actually needs is
  clause exhaustiveness - a final catch-all clause, matching
  `otel_telemetry.erl`'s own `handle_event(_, _, _, _) -> ok.` and ecto's
  `defp query_opts(_), do: %{}` - not rescue-to-default. Every clause added
  here (Phase 3 adds the two macrostep clauses) must bind only the keys it
  needs in its head, so a malformed or unrecognised event falls through to
  the catch-all and drops the span rather than raising.
  """

  alias OpentelemetryStatifier.Config

  @spec handle_event(:telemetry.event_name(), map(), map(), Config.t()) :: :ok
  # Phase 3 adds the two macrostep clauses above this one. Until then every
  # event - the 25 unmapped names, and any malformed measurements/metadata
  # on any name - falls straight through here.
  def handle_event(_event, _measurements, _metadata, _config), do: :ok
end
