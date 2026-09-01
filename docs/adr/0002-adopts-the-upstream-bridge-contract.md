# ADR-0002: This package is bound by the upstream bridge contract

Status: accepted (2026-08-20)

Cross-repo citations here use the family convention: a beads-prefix
qualifier on the ADR number (`st-ADR-0062` is statifier-ex's ADR-0062;
a bare `ADR-NNNN` is always this repository's own).

## Context

This repository exists because st-ADR-0062 decided the OpenTelemetry
bridge for the statifier family is a separate package rather than an
optional module inside statifier - named `opentelemetry_statifier` for the
OTel ecosystem convention, scoped to the whole package family, and
consuming only public telemetry contracts. The bridge-facing design (span
topology, context propagation, attribute mapping, cardinality, failure
tolerance, trace-off degradation) is recorded in statifier-ex's
`docs/opentelemetry.md`; the event contract itself is st-ADR-0040 and the
`Statifier.Session.Telemetry` moduledoc.

Those records bind this package from outside. Left implicit, the binding
would erode: the constraints live in another repository's history, and
nothing here would say they were ever accepted rather than merely known
about.

## Decision

This package adopts the upstream records as binding, by reference:

1. **Public events only.** The bridge consumes the `:telemetry` events the
   family documents, and nothing else. When it needs data the events lack,
   the fix is the upstream contract gaining a field (raised in the owning
   repo; the caller-context slot is already statifier-ex's st-yoi0), never
   an internal reach from here.
2. **Family scope.** Sibling packages' telemetry surfaces
   (statifier_persistence, statifier_oban, statifier_ui, predicator) are
   bridged in this package as separate per-library setup calls, the shape
   `opentelemetry_ecto` and `opentelemetry_oban` compose in a host.
3. **The design note governs the mapping.** statifier-ex
   `docs/opentelemetry.md` is the reference for span topology, links,
   attribute namespace (`statifier.*`), the datamodel-values opt-in, and
   trace-off degradation. Deviations are decided in an ADR here and fed
   back as a correction there, not improvised in code.
4. **Dependency and publish policy.** statifier is taken as a git pin to a
   `main` SHA under st-ADR-0061's contract; this package stays unpublished
   until statifier is on Hex, and wanting to publish is st-ADR-0061
   decision 5's trigger firing upstream, not a decision this repo can take
   alone.
5. **API dependency discipline.** `lib/` depends on `opentelemetry_api`
   only; the SDK appears in the test environment alone.

## Consequences

- The upstream freeze cuts both ways: statifier-ex treats the 27 event
  names and shapes as a public commitment once this bridge ships against
  them (st-ADR-0040's consequences), and this package gets breaking-change
  visibility through statifier's `changelog.d/` diff between pins.
- Handler modules, ETS span-table ownership, sweeper design, and the setup
  API are this repository's decisions - future ADRs here, judged against
  the design note rather than re-litigating it.
- What would reopen this record: st-ADR-0062 being amended (packaging or
  scope), or the design note moving in a way that contradicts an ADR
  already accepted here.

## Notes

**2026-09-01: decision 4 is resolved.** Statifier 2.x is on Hex, so
st-ADR-0061 decision 5's trigger has fired upstream and st-ADR-0066 is
the re-decision that replaced the git-pin contract. This package now
takes statifier as an ordinary Hex requirement - `mix.exs` states the
requirement and `mix.lock` resolves it to a version and a checksum,
rather than to a `main` SHA - and it publishes: 0.1.0, 0.1.1, and 0.1.2
are on Hex.

Decision 4 is left as written rather than rewritten. It records what was
decided on 2026-08-20 under the contract in force then, and the
condition it named is exactly the one that fired; rewriting it would
erase the trigger along with the wait. Decisions 1, 2, 3, and 5 are
untouched by this and still bind, so the record stays accepted rather
than superseded.
