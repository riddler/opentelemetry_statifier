# Architecture Decision Records

| # | Decision | Status |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions | accepted |
| [0002](0002-adopts-the-upstream-bridge-contract.md) | This package is bound by the upstream bridge contract: public events only, family scope, the statifier-ex design note governs the mapping, and a dependency and publish policy since resolved (see the record's Notes) | accepted |
| [0003](0003-handler-attach-and-span-table-mechanism.md) | Handler attach and span table mechanism: per-event handler ids, an idempotent setup/1, a supervised ETS span table with tagged keys, no opentelemetry_telemetry dependency, fresh-context root spans | accepted |
| [0004](0004-sibling-setup-calls-and-bridge-owned-nesting.md) | Sibling setup calls, and nesting owned by the bridge's table: one independent setup per sibling family, literal event lists and no sibling dependency, three span shapes, per-package attribute namespaces, and caller_context as a link (amends ADR-0003 decision 8) | accepted |

New ADRs: next number, same three-section format (Context, Decision,
Consequences). Pick the number against a freshly fetched remote. A bare
`ADR-NNNN` cites this repository's own records; a cross-repo citation
carries the owning repo's beads prefix (`st-ADR-0040` is statifier-ex's
ADR-0040).
