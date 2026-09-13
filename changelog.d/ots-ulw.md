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
- The durable floor is **`statifier_persistence` 0.12**: there is no dual
  emit upstream, so below 0.12 the six renamed event names are attached to
  names that release does not emit and the spans they carry simply stop -
  no `statifier_persistence.execution.step`, no `.execution.lock`, and no
  `.execution.created` / `.terminated` / `.discarded`. Upgrade
  `statifier_persistence` and this package together.
- Below that floor the ten names that did not move still arrive and still
  become spans, in two shapes. The nine point events - `identity.refused`,
  `effect.failed`, `drive.turns_exhausted` and the six `child.*` events -
  land as unparented root spans instead of as span events on the step.
  `adapter.call` is not one of them: it carries a `duration`, so it is
  always a span of its own back-dated by that duration, nested in the step
  span when one is open and a root when none is - except that a host which
  declared its own span through `OpentelemetryStatifier.Parent.register/2`
  still parents it, which the nine point events do not read. The other two
  families (`OpentelemetryStatifier.setup/1`'s statechart events and
  `OpentelemetryStatifier.Oban`) are unaffected.
- `OpentelemetryStatifier.Persistence.events/0` returns **16** names,
  not 14: `[:statifier_persistence, :child, :recorded]` and
  `[..., :child, :settled]` are bridged. They were added upstream after
  `statifier_persistence` 0.5.0 and had gone unbridged because this
  package's drift check was pinned to that release.
