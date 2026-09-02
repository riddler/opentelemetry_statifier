### Added

- `OpentelemetryStatifier.SpanContext.lookup/2` resolves the open macrostep
  span for a `(session_id, macrostep)` pair to its W3C trace and span ids, so
  a `statifier_ui` subscriber can be wired to it as an `:otel_context`
  producer directly.
