# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

## Beads issue tracker

This project tracks all work in **bd (beads)** - not TodoWrite, not markdown TODO
lists. Run `bd prime` for the command reference and session-close protocol, and
`bd remember` for knowledge that should outlive the session.

Claude Code injects `bd prime` at session start, so this section is deliberately
a stub.

Note for `bd` maintainers: `bd integrate --update` will want to re-expand this
into the full managed block. It is redundant here - keep the stub.

### Beads that span repositories

Two trackers touch this project routinely: `ots-` here, and `st-` in
statifier-ex. The design bead that created this repository is `st-cmq.2`, and
the sibling packages this bridge will eventually cover carry their own design
beads (`sp-`, `sob-`, `sui-`, `px-`), each mirroring `st-cmq.2`.

| Situation | Rule |
|---|---|
| A decision is recorded in both trackers and they disagree | The repository whose files change owns the decision. The telemetry event contract - names, measurements, metadata, the fields on the effect structs - is statifier-ex's call (st-ADR-0040) and this repo defers; how those events map to OTel spans, events, links, and attributes is this repo's call |
| A bead pairs with one in another tracker | Both halves carry `mirrors: <id>` as the first line of the description |
| You are about to schedule, claim, plan against, or cite the status of a mirrored bead | Re-read the other tracker first and write a new dated note above the old one, then act |
| A `mirrors:` line names an id that no longer resolves | Broken immediately, not stale. Fix it with one `bd update` the moment you notice |
| The bridge needs data the public events lack | Say so and raise it in statifier-ex (the caller-context slot is already `st-yoi0` there). Never reach past the public contract: consuming internals is the failure st-ADR-0062 exists to prevent |

## Agent authority in this repo

**This repository has not opted into any expanded profile, so the conservative
rules `bd prime` describes apply in full.** Agents track work in bd, run the
tests, and report; commits, pushes, requests, and bead closes are human calls.

Adopting statifier-ex's team-maintainer profile is a decision for a human to
make and record here. Do not infer it from that repo, from this file's
resemblance to that one, or from the fact that the same person works on both.

## Non-interactive shell commands

`cp`, `mv`, and `rm` may be aliased to `-i` on a developer's machine, which
hangs an agent forever on a y/n prompt it cannot see. Always pass the
non-interactive form: `cp -f`, `mv -f`, `rm -f`, `rm -rf`, `cp -rf`. Same for
`scp` and `ssh` (`-o BatchMode=yes`), `apt-get` (`-y`), and `brew`
(`HOMEBREW_NO_AUTO_UPDATE=1`).

Also avoid `bd edit`, which opens `$EDITOR` and blocks. Use
`bd update <id> --title/--description/--notes/--design` instead.

## What this project is

`opentelemetry_statifier`: OpenTelemetry instrumentation for the
[Statifier](https://github.com/riddler/statifier-ex) family of statechart
packages, in the `opentelemetry_oban` / `opentelemetry_ecto` mold - the
library emits `:telemetry`, this package turns it into OTel.

**Nothing is implemented yet.** The repository holds the scaffold only, so
almost every convention below is inherited rather than demonstrated.

Always refer to state machines as **state charts**, as statifier-ex does.

### Read before writing any code here

The design this package implements is recorded in statifier-ex, and this
repo's ADRs adopt it rather than restating it:

- statifier-ex `docs/opentelemetry.md` - span topology (a macrostep is a
  span, paired on `span_ref`; effect/trace events are span events; one
  trace per macrostep, stitched with links), context propagation and its
  session-process caveat, attribute mapping, cardinality policy, failure
  tolerance, and trace-off degradation.
- st-ADR-0062 - packaging and scope: this package is
  family-scoped, consumes only public telemetry events, git-pins statifier
  `main` SHAs under st-ADR-0061, and stays unpublished until
  statifier itself is on Hex.
- st-ADR-0040 (plus `Statifier.Session.Telemetry`'s moduledoc,
  the single authoritative event table) - the 27-event contract this
  bridge consumes.
- `docs/adr/` here - ADR-0001 records the ADR practice; ADR-0002 records
  this repo's adoption of the constraints above as binding.

Two rules that do not wait to be looked up:

- **Public events only.** If the bridge needs data the events lack, the fix
  is the contract gaining a field upstream (raise it in statifier-ex),
  never a workaround here.
- **Nothing unbounded reaches an attribute by default.** Datamodel values
  (`:datamodel_change`'s `new_value`/`prior_value`, `:datamodel_init`'s
  map) are opt-in at setup, never exported by default.

## Build & Test

```bash
mix quality                  # full gate: format, compile, credo, dialyzer,
                             # deps audit, full suite with coverage
mix quality --profile loop   # inner loop: format, compile, credo, changed tests
mix test                     # the suite
```

Full `mix quality` must be green before any commit. The gate formats your
code - do not run `mix format` as a separate step.

Set `STATIFIER_PATH` to a local statifier-ex checkout when co-developing a
change that spans both repos; otherwise the git pin in `mix.lock` governs.

## Conventions

Inherited from statifier-ex unless this project records otherwise:

- Errors are events: evaluations return `{:ok, v} | {:error, e}`. Never
  rescue-to-default at a leaf. The one nuance here: a telemetry handler that
  raises is detached by `:telemetry` itself - handlers must be defensive at
  the boundary, and a malformed event is a dropped span, never a crashed
  session.
- Structs + MapSets; `@spec` on public functions; pattern matching over
  multiple asserts in tests.
- Functions taking a state/session put it as the first argument (pipeline
  threading).
- Sabotage every new test that asserts `lib/` behavior: break the code it
  covers, confirm it goes red, revert, and note the mutation in one line
  above the test - `# sabotage: <what was broken> -> red`.
- Commit messages: title < 50 chars, simple present tense ("Adds ...",
  "Fixes ..."), body wrapped at ~72 chars. No AI attribution trailers.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->
