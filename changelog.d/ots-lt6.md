### Added

- Cleans up the span table over the session lifecycle: `:terminate`
  removes the session's rows (ending a still-open macrostep span with an
  error status), and a periodic sweep does the same for sessions whose
  process died without a `:terminate`, so a brutal kill orphans no open
  span and leaks no rows. With `trace: false` the bridge degrades to
  macrostep-grained spans with effect-level span events, no
  configuration needed.
