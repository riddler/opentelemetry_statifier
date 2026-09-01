### Added

- Adds `OpentelemetryStatifier.Persistence.setup/0,1`, bridging the fourteen
  `[:statifier_persistence, ...]` events into a `statifier_persistence.run.step`
  span with the storage, lock and lifecycle detail inside it.
- Adds `OpentelemetryStatifier.Oban.setup/0,1`, bridging the eleven
  `[:statifier_oban, ...]` events: scheduling events onto the macrostep span
  that armed them, and each delivery event as its own span linked to the
  arming trace through `caller_context`.

### Changed

- A macrostep span now nests inside the `statifier_persistence.run.step` span
  around it, instead of always rooting its own trace. With no sibling setup
  attached, nothing changes.
