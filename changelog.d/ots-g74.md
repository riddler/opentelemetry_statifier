### Added

- `OpentelemetryStatifier.Persistence` bridges `statifier_persistence`'s batch migration span: a `migrate_batch/3` call becomes a `statifier_persistence.execution.migrate_batch` span carrying the report's counts as attributes, and each execution it moves lands on it as a `migrated` span event.

### Changed

- Inside a `statifier_persistence` `migrate_batch/3` call, the `statifier_persistence.execution.lock` and `statifier_persistence.adapter.call` spans each execution's turn opens now nest under the batch span, where they were the roots of their own traces, and each migrated execution is a `migrated` span event on the batch span, where it was a zero-duration root span of its own.
