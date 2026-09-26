### Added

- A `statifier_persistence` step that raises, throws or exits now records an
  `exception` span event on its step span, carrying `exception.type` and the
  narrowed frames as `exception.stacktrace`, so a tracing backend's exception
  view shows the failure.
