# OpentelemetryStatifier

OpenTelemetry instrumentation for the
[Statifier](https://github.com/riddler/statifier-ex) family of statechart
packages - in the `opentelemetry_oban` / `opentelemetry_ecto` mold: the
libraries emit `:telemetry` events, this package turns them into
OpenTelemetry spans, span events, and span links. It depends only on
`opentelemetry_api`; hosts bring their own SDK and exporter.

**Status: design phase.** Nothing is implemented yet. The design this
package implements is recorded in statifier-ex:

- [`docs/opentelemetry.md`](https://github.com/riddler/statifier-ex/blob/main/docs/opentelemetry.md) -
  span topology, context propagation, attribute mapping, cardinality
  policy, and trace-off degradation.
- [st-ADR-0062](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0062-opentelemetry-bridge-is-a-separate-package.md) -
  packaging and scope: family-scoped, public-events-only, and unpublished
  until statifier itself is on Hex.

The short version of the design: a statechart macrostep is a span; effect
and trace telemetry events are span events on it; there is no
session-lifetime span; each macrostep roots its own trace, stitched to its
neighbors (previous macrostep, invoking parent) with span links; nothing
unbounded is exported as an attribute by default.

## Installation

Not published to Hex - statifier itself is unpublished, and a Hex package
cannot carry a git dependency, so this package pins statifier `main` SHAs
under [st-ADR-0061's contract](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0061-sha-pinning-contract-until-2-0-0.md)
and asks the same of its consumers:

```elixir
def deps do
  [
    {:opentelemetry_statifier,
     github: "riddler/opentelemetry_statifier", ref: "<pinned sha>"}
  ]
end
```

## License

MIT - see [LICENSE](LICENSE).
