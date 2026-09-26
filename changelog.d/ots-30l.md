### Added

- `OpentelemetryStatifier.Oban` bridges `[:statifier_oban, :invoke, :deferred]`,
  the event `statifier_oban` 0.15 emits when an invoke handler defers its
  answer: it becomes a `statifier_oban.invoke.deferred` span of its own,
  like the other delivery-seam events, and is the last span this bridge
  produces for that invocation.
