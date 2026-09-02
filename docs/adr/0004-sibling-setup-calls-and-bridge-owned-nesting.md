# ADR-0004: Sibling setup calls, and nesting owned by the bridge's table

Status: accepted (2026-09-01)

Cross-repo citations here use the family convention: a beads-prefix
qualifier on the ADR number (`st-ADR-0062` is statifier-ex's ADR-0062,
`sp-ADR-0009` is statifier_persistence's, `sob-ADR-0006` is
statifier_oban's; a bare `ADR-NNNN` is always this repository's own).

## Context

Two siblings landed telemetry surfaces of their own: `statifier_persistence`
emits fourteen `[:statifier_persistence, ...]` events under sp-ADR-0009,
and `statifier_oban` emits eleven `[:statifier_oban, ...]` events under
sob-ADR-0006. Both records freeze their contracts, both tabulate them in
the emitting repo's `docs/telemetry.md`, and both end with a section
titled "The bridge half" that states the same thing: span construction,
handler attachment and the span table are this repository's decisions.

ADR-0002 decision 2 already fixed the packaging answer - siblings are
bridged here as *separate per-library setup calls*, the shape
`opentelemetry_ecto` and `opentelemetry_oban` compose in a host - and
ADR-0003 fixed the attach and span-table mechanism for the interpreter
family. `ots-dxr` is the first slice that has to apply both to a second
and third family, and doing so surfaced one question neither record
answers: **what parents a durable macrostep span.**

ADR-0003 decision 8 says a macrostep span starts from a fresh
`OpenTelemetry.Ctx.new/0`, never the process's ambient context, and is
never attached to the process context - which is what makes each
macrostep the root of its own trace and what stops the bridge clobbering
a host's context inside a session process. But statifier-ex's
`docs/opentelemetry.md` (as amended by st-ADR-0067 decision 5) and sp's
`docs/telemetry.md` both describe a durable macrostep span *nesting
inside* the step span the persistence layer opened around it, "by
ordinary OTel ambient context, since both run in the same process during
the call". Taken literally those two are incompatible: a span that starts
from an empty context is nobody's child, however many spans are ambient.

## Decision

1. **One setup call per sibling family, and they are independent.**
   `OpentelemetryStatifier.Persistence.setup/0,1` and
   `OpentelemetryStatifier.Oban.setup/0,1`, each with its own
   `teardown/0` and its own `events/0`, each idempotent in exactly the
   way `OpentelemetryStatifier.setup/1` is, and none of them attaching,
   detaching, or validating anything outside its own family. A host
   attaches the ones it runs. This is ADR-0002 decision 2 applied, not
   re-decided.

2. **The same per-event handler-id discipline, per family.** One
   `:telemetry.attach/4` per event name under `{module, event_name}`,
   never `attach_many/4` - ADR-0003 decision 2's reasoning transfers
   unchanged, and applies with more force here: an `attach_many/4` across
   a sibling family would let one malformed adapter-call event take the
   step spans down with it for the VM's lifetime.

3. **Event names are literal in this repository, and this package takes
   no dependency on its siblings.** Both sibling notes point out that
   their `events/0` exists so the bridge need not hand-copy a list, and
   both are right - but importing it would make `statifier_persistence`
   (and Ecto, and a database driver) or `statifier_oban` (and Oban) a
   dependency of every host that wants statechart tracing, which is the
   dependency direction st-ADR-0062 exists to avoid. The contracts are
   frozen by accepted ADRs upstream, so a literal list is safe between
   sibling releases; `ots-41k` adds test-only optional deps and a drift
   test comparing the two lists once both siblings are on Hex with their
   `Telemetry` modules.

4. **Nesting runs through this bridge's own span table, never the
   process's ambient OTel context.** A `[:statifier_persistence, :run,
   :step, :start]` opens a `statifier_persistence.run.step` span and
   records it, with the context that has it as the current span, under a
   row keyed by `span_ref` and *tagged with the emitting pid*. Every span
   the bridge opens afterwards in that process - the durable macrostep
   span, an adapter-call span, a lock span - starts from that stored
   context.

   This amends ADR-0003 decision 8 to exactly this extent: a macrostep
   span is still never started from, and never attached to, the process's
   ambient context, and it is still the root of its own trace whenever
   this bridge has nothing open around it. What changes is that a span
   *this bridge itself* opened, in *this* process, parents it. That
   produces the topology the design note and sp's note describe, while
   keeping both of decision 8's guarantees: the bridge cannot inherit a
   host's unrelated request span, and it cannot clobber a host's context.
   Reading the ambient context would have satisfied the first sentence of
   those notes and quietly broken "one trace per macrostep" for every
   existing consumer, because a host with any span open at step time
   would have captured every macrostep into it.

5. **Three span shapes, decided by the contracts rather than per event.**
   A `:start`/`:stop` pair becomes a span (only sp's step seam has one).
   A point event carrying a `duration` - `[..., :adapter, :call]` and
   `[..., :run, :lock]` - becomes a span back-dated by that duration,
   because the interval it reports has already closed. Everything else is
   a point: a span event on the bridge span open around it, and its own
   zero-duration span when there is none. The fallback matters most for
   sob's delivery seam, which fires inside an Oban job where this bridge
   has nothing open at all.

6. **A point event lands only on a span open in its own process.** For
   sp's family that is the innermost step span for `self()`. For sob's
   scheduling seam it is the macrostep span open for `scope` - and only
   when the `:session_pid` row for that scope is `self()`, so a
   delivery-seam event never writes onto a span another process holds for
   the same scope.

7. **Per-package attribute namespaces, one shared correlation key.** sp's
   keys map into `statifier_persistence.`, sob's into `statifier_oban.`,
   and each family's correlation key - `session_id` there, `scope` here -
   is aliased onto `statifier.session_id`, the attribute that joins a
   step, a timer and a macrostep. `monotonic_time` and `system_time` are
   dropped as clock plumbing the span's own timestamps already carry;
   `duration` is kept. Every other rule in `Attributes` applies unchanged
   inside whichever namespace is in force.

8. **`caller_context` becomes a link and never an attribute.** On sob's
   delivery seam the bridge reads the slot, and where the host wrote the
   W3C text form (`%{"traceparent" => "00-..."}`) the fired span carries a
   *link* to the arming trace - never a parent, which would hold that
   trace open for the length of the delay. Anything else links to
   nothing, `nil` included; that is the ordinary detached case, not an
   error. The traceparent is parsed here rather than through a propagator
   because every propagator API extracts *into* a process context, which
   decision 4 forbids this bridge from touching.

## Consequences

- **Two deviations from what the sibling notes anticipated**, both
  recorded here and owed back as corrections there (ADR-0002 decision 3's
  discipline):

  - sob's note says its keys "map by name into the `statifier.`
    namespace". They map into `statifier_oban.` instead, with `scope`
    aliased onto `statifier.session_id` exactly as that note asks. sp's
    note, written later, already specifies the per-package form for its
    own keys, and a bridge whose three families share one namespace makes
    `statifier.reason` mean three different vocabularies.
  - Both notes describe nesting as "ordinary ambient context". It is
    ordinary parent-child nesting, but the parent comes from this
    package's ETS table rather than from the process dictionary, for
    decision 4's reason. Nothing an emitting package does changes; the
    correction is to the sentence, not to either contract.

- **A host that attaches `OpentelemetryStatifier.Persistence.setup/0`
  without `OpentelemetryStatifier.setup/0` gets step spans with nothing
  inside them.** sp's family one is the interpreter's own contract with
  `driver: :persistence`, and the existing setup already bridges it.

- **Sibling rows are swept on process liveness, like session rows.** Both
  halves of a step arrive inside one synchronous call, so the only way to
  orphan one is for the driving process to die mid-step; there is no
  `:terminate`-shaped hook on that path, so `SpanTable.sweep/1` is the
  whole cleanup story for these rows and ends them with an error status.

- **What would reopen this record**: a sibling contract growing a
  `:start`/`:stop` pair of its own (decision 5 would need a home for it),
  the durable-subchart seam wanting parenthood rather than a link between
  a parent run's step and a child's, or a decision to depend on the
  siblings after all, which would replace decision 3 and let `events/0`
  drive the attach list directly.

## Notes

**2026-09-02: decision 4 is generalized to a public registration
(`ots-cwu`).** Decision 4 gave the durable macrostep span a parent, and
named exactly one thing that could be it: a span *this bridge itself*
opened, in this process, from a sibling package's `:start` event. In
practice that meant `statifier_persistence`'s step seam and nothing
else. A host running its own durable stepper - its own storage, its own
lock, its own step span - got the ordinary topology instead: a macrostep
rooting its own trace, linked to its neighbours, with the host's step
span nowhere in the tree.

Decision 4's reasoning never turned on the parent being the family's
stepper. It turned on the parent being *declared* rather than *ambient*:
what it refuses is reading `OpenTelemetry.Ctx`, because a host with any
unrelated span open at step time would then capture every macrostep into
it and "one trace per macrostep" would break silently for every existing
consumer. An explicitly handed-in span is not that. So decision 4 is
generalized from the family's durable stepper to *a* durable stepper,
along exactly the axis that leaves its guarantee intact:

- **The public door is `OpentelemetryStatifier.Parent`.**
  `register/2` takes the span context the host means, and
  `unregister/1` withdraws it; `within/3` is the scoped form and
  withdraws on the way out, raises included. A declaration lives from the
  `register/2` that made it until it is withdrawn or swept - it is not
  scoped to a macrostep, a session, or a call.
- **ADR-0003 decision 8 is unchanged, in both directions.** The bridge
  still never reads the process's ambient context and still attaches
  nothing to it. The declared context is built from a fresh
  `OpenTelemetry.Ctx.new/0` with the handed-in span set as current, which
  is the same construction decision 4 already performs for a sibling
  span. A macrostep with no declaration and no open sibling span is still
  the root of its own trace.
- **It opens a row, not a key shape.** The declaration is a
  `{{:parent_span, ref}, pid, %ParentEntry{}}` row in the same table,
  carrying a pid in element 2 for the same reason the `:sibling_span`
  row does - the lookup is "is something of mine open around me, in this
  process". The `:sibling_span` key shape decision 4 fixed is untouched;
  this is a second row tag beside it, and
  `SpanTable.fetch_enclosing_ctx/2` orders the two kinds against each
  other on the one clock they share, so the innermost wins whichever kind
  it is.
- **Keyed on the process whose spans nest, defaulting to `self()`.**
  That is the shape a driver stepping a session synchronously in its own
  process wants, and it is the shape the family's own stepper already
  has. A driver stepping a session in another process passes `pid:`.
- **A declaration is a parent and nothing else.** The bridge never ends
  the declared span, never sets an attribute on it, and never lands a
  span event on it - decision 6's point-event hosts stay the bridge's own
  spans. The span's lifetime is entirely the host's.
- **A missing or dead registrant degrades to a root.** A `register/2`
  that cannot record the declaration returns `{:error, reason}` -
  `:invalid_span`, `:registrant_not_alive`, `:no_span_table`, or an
  unknown option - and the caller carries on untraced rather than
  crashing; `within/3` runs its block either way, because instrumentation
  does not decide whether a host's work happens. A registrant that dies
  without withdrawing is an abandoned declaration: nobody is left to end
  the declared span, so from that moment the lookup skips the row and
  macrostep spans root their own traces again, and the sweep deletes the
  row **without** ending the span - this bridge did not open it and does
  not know whether the work it covers has finished. That is the one place
  the two row shapes are treated differently, and ownership is why.
- **The family's own path is unchanged when the API is unused.** With no
  declaration ever made, every span in this package is byte-identical to
  what decision 4 produced: `statifier_persistence`'s step seam still
  parents the durable macrostep span, an adapter call still nests in its
  step, and a host that attached neither sibling setup still gets one
  root trace per macrostep. The existing tests that assert those
  topologies are unchanged by `ots-cwu`.

Decision 4 is left as written rather than rewritten: it records what was
decided for the sibling seam and the reasoning that generalizes, and the
generalization is an extension of its mechanism rather than a
replacement for it. Decisions 1, 2, 3 and 5 through 8 are untouched, so
the record stays accepted rather than superseded.

What would reopen *this* note, on top of what the Consequences already
list: a host wanting its declared span to receive span events as well as
parenthood (decision 6 would need a home for a span the bridge does not
own), or a driver wanting to declare a parent for a session it steps
from many processes at once, which the pid key cannot express.
