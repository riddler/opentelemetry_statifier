### Fixed

- A `statifier_oban` scheduling event now falls back to the step span open in
  the emitting process when `scope` is a host's durable run id, instead of
  rooting a trace of its own.

### Changed

- 2026-09-06: corrects the 0.3.0 entry for `OpentelemetryStatifier.Oban.setup/0,1`.
  A scheduling event lands on the macrostep span that armed it when the session
  is stepping in the emitting process, and on the step span open there under a
  durable driver.
