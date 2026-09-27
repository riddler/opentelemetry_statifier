### Changed

- The `statifier_persistence.dropped` attribute of a migration's
  `statifier_persistence.execution.migrated` point is now a sorted string
  array of the dropped state ids, as `statifier.configuration` is, instead of
  one `inspect/1` string; a host that parsed or matched that string queries
  the array's elements instead.
