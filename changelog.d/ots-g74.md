### Added

- `OpentelemetryStatifier.Persistence` bridges `statifier_persistence`'s batch migration span: a `migrate_batch/3` call becomes a `statifier_persistence.execution.migrate_batch` span carrying the report's counts as attributes, and each execution it moves lands on it as a `migrated` span event.
