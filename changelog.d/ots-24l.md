### Added

- `OpentelemetryStatifier.Oban` bridges `statifier_oban`'s three fan-out
  events. `invoke.fan_out` and `invoke.child_started` become roots linked
  to the trace that planned the invocation, so every chunk child is
  reachable from the parent's dispatch by a link edge rather than only by
  a shared `statifier.session_id`; `invoke.unstarted_cancelled` carries no
  caller context and lands as a span event on the span open where the
  sweep ran, putting its count in the trace either way.
