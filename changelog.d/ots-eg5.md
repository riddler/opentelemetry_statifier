### Added

- A setup option, `adapter_calls: :nested_only | :all`, chooses whether a `statifier_persistence.adapter.call` span is emitted only inside an enclosing span (`:nested_only`) or for every adapter call (`:all`).

### Changed

- Adapter call spans outside an enclosing span are no longer emitted under the default option, `adapter_calls: :nested_only`; pass `adapter_calls: :all` to `OpentelemetryStatifier.Persistence.setup/1` to keep every adapter call span.
