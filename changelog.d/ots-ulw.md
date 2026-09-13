### Changed

- **Breaking for `OpentelemetryStatifier.Persistence` span names.**
  `statifier_persistence` retired `run` as the noun naming the durable
  record (its ADR-0011), so the bridge moves to the `:execution` event
  prefix in lockstep: the step span is now
  `statifier_persistence.execution.step` (was
  `statifier_persistence.run.step`), the lock span is
  `statifier_persistence.execution.lock`, and the lifecycle point spans
  are `statifier_persistence.execution.created` / `.terminated` /
  `.discarded`. `statifier_persistence.adapter.call`,
  `.identity.refused`, `.effect.failed`, `.drive.turns_exhausted` and
  the `.child.*` seam keep their names. The `run_id`-shaped metadata
  keys arrive as `execution_id`, `parent_execution_id` and
  `child_execution_id`, so the attributes they become are
  `statifier_persistence.execution_id` and friends. Update saved
  queries, dashboards and alerts that name the old spans or attributes.
- The durable floor is **`statifier_persistence` 0.12**. There is no
  dual emit upstream and no old-prefix subscription left here, so this
  bridge half is silent against `statifier_persistence` below 0.12 -
  the handlers attach to names that release does not emit. The other
  two families (`OpentelemetryStatifier.setup/1`'s statechart events and
  `OpentelemetryStatifier.Oban`) are unaffected.
- `OpentelemetryStatifier.Persistence.events/0` returns **16** names,
  not 14: `[:statifier_persistence, :child, :recorded]` and
  `[..., :child, :settled]` are bridged. They were added upstream after
  `statifier_persistence` 0.5.0 and had gone unbridged because this
  package's drift check was pinned to that release.
