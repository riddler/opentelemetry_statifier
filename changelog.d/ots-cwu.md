### Added

- `OpentelemetryStatifier.Parent.register/2`, `unregister/1` and `within/3`
  let a host with its own durable stepper declare the span its macrostep
  spans nest inside, the way `statifier_persistence`'s step span already
  does.
