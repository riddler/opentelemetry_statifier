### Added

- Records the effect, trace, `:interpret`, `:unroutable`, and `:halt`
  telemetry events as span events on the open macrostep span, and links
  each macrostep span to the session's previous macrostep and (for an
  invoked child's `:initialize` macrostep) to the invoking parent's open
  span. Datamodel values are excluded unless `setup/1` receives
  `record_datamodel_values: true`.
