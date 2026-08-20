# ADR-0001: Record architecture decisions

Status: accepted (2026-08-20)

## Context

This package implements a design owned elsewhere (statifier-ex's ADR-0040
telemetry contract and its ADR-0062 packaging decision), which makes it
easy for local decisions - handler layout, ETS table ownership, attribute
naming, test harness shape - to accumulate as unrecorded folklore, or
worse, to quietly drift from the upstream records they depend on.

statifier-ex records decisions as ADRs under `docs/adr/`, numbered
sequentially, with a three-section format (Context, Decision,
Consequences) and an index table in `docs/adr/README.md`. Citing an ADR
number ends re-argument; amending one is explicit.

## Decision

This repository records architecture decisions the same way: numbered
ADRs under `docs/adr/`, three-section format, indexed in
`docs/adr/README.md`, next free number picked against a freshly fetched
remote. A decision owned by another repository is adopted by reference in
an ADR here (ADR-0002 is the first), never restated in a way that could
drift.

## Consequences

- Design decisions land as ADRs before or with the code that encodes
  them; cite numbers instead of re-arguing.
- Cross-repo authority follows the umbrella rule: the repository whose
  files change owns the decision. Event-contract questions go to
  statifier-ex; span-mapping questions are decided here.
- No automated ADR tooling (statifier-ex's guard and judge) is adopted
  yet; that is a decision to record when there is an ADR set worth
  protecting mechanically.
