### Added

- `OpentelemetryStatifier.Persistence` bridges the four events
  `statifier_persistence` 0.19 emits that it did not: a step that raised,
  threw or exited closes its `statifier_persistence.execution.step` span
  with an error status, an `error.communication` re-entry lands as a
  `statifier_persistence.execution.step.reentered` span event on the step
  span, and an execution migrated or unparked becomes a point like the
  other lifecycle events.
