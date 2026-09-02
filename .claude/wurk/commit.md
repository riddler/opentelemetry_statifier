# Opentelemetry_statifier extension: /wurk:commit

Additional required steps and project facts. Adds only - see
`~/.claude/skills/wurk:commit/SKILL.md` for everything this does not repeat.

## Authority: consent-scoped, and the local gate is the check

The trigger for `git commit` is the authority table in this repo's
`CLAUDE.md`, which this file points at and does not restate: a campaign
carrying the operator's explicit consent, the bead's work complete, and full
`mix quality` green. That section is operator-adopted; nothing here widens or
narrows it.

Two consequences worth spelling out at commit time:

- **The full local gate is what gates the commit.** CI runs the full gate,
  but only for pushes to `main` and requests targeting `main` - it runs
  after the commit, not before it, and a stacked request (base is another
  branch) triggers no CI at all. A `--profile loop` green is not the
  trigger - it skips dialyzer, deps audit, and coverage.
- **A diff touching no Elixir code has no gate to run** and may commit on
  review of the diff alone (the authority table says so explicitly). The
  manifest's `gate.build_paths` is the boundary: a docs-only or
  `.claude/`-only change falls outside it. Say in the commit body review that
  this is why the gate did not apply, rather than leaving it ambiguous.

## Sabotage discipline (the project's answer to `data.sabotage.missing`)

`data.sabotage.missing` is a report, not a gate, per the generic skill - but
this project's convention (CLAUDE.md: sabotage every new test that asserts
`lib/` behavior) makes it a real refusal condition:

- A test with no `# sabotage:` note directly above it has been *observed*
  passing, not *verified*. Break the `lib/` code it covers, confirm it goes
  red for the right reason, revert, confirm green, then write the one-line
  note above the test: `# sabotage: <what was broken> -> red`. Re-run the
  gate afterward.
- Never invent a note for a mutation that was not run - a fabricated note is
  the one failure mode this check cannot catch afterward. Refuse and report
  which tests are unverified instead.
- There are no exempt test roots here (`gate.sabotage.exempt_prefixes` is
  empty); every `lib/`-asserting test carries a note.

## Changelog: fragments, judged by changelog.d/README.md

`changelog.mode` is `fragments` with `dir: changelog.d`. The needs/no-entry
test is written down in `changelog.d/README.md` - one file per bead, named
`changelog.d/<bead-id>.md`, standard Keep a Changelog headings, entries only
for changes visible to someone calling the public API. Scaffold, agent
tooling, and docs work needs no fragment - `changelog.d/README.md` names those
categories explicitly - and that is the expected outcome, not a step you
skipped.

## Version bump: only on a release bead

`mix.exs` holds whatever version the last release bead set. Read it; this
file quotes no number, on purpose - a version pinned in prose here goes
stale the release after it is written.

The boundary is `CLAUDE.md`'s authority table, which this file points at and
does not restate. Its *version bump on a release bead's branch* row allows
the bump only on an operator-authorized release bead inside a campaign
carrying the operator's explicit consent, and its *release (tag,
`mix hex.publish`, GitHub release)* row allows those never. So at ordinary
commit time the answer is unchanged: never edit the version field as part of
a commit that is not a release prep. `.claude/wurk/release.md` is the recipe
for the one case where it moves.

## Gate thresholds are the operator's call

`gate.moving_files` lists `.quality.exs` and `coveralls.json`. A diff that
moves a number in either needs the operator to have asked for it - "the gate
went red and the threshold looked too strict" is the signal working, not a
reason to move it. Report the finding and stop. `.quality.exs` records why
this gate is deliberately smaller than statifier-ex's; a change that moves a
value without moving its reason is incomplete regardless of who asked.

## Gate attestation: `mix quality.verify`, provided by ex_quality

The manifest wires `gate.attest` to `mix quality.verify`. The task ships in
`ex_quality` (`~> 0.14`, dev-only, locked at `0.14.0`), so this repo carries
no local copy of it, on purpose, per the family ruling in st-hcgl. It adds no
gate stage and modifies nothing in `.quality.exs`; it runs the gate with a
machine-readable report and attests only a full run (status ok, scope all, no
profile, no run-narrowing skip). An unattended (`/wurk:commit --auto`) run
advances only on `attested: true` - a run that reports `attested: false` was
narrowed and is refused. Never fake an attestation; re-run the bare command
instead.

The earlier wiring named `mix gate.verify` (bead `ots-4l6`), described here as
shipping with the `statifier` dep. It does not. The task exists in
statifier-ex's git tree (`lib/mix/tasks/gate.verify.ex`), but that repo's
package `files:` list is `lib/statifier lib/statifier.ex mix.exs README.md
LICENSE CHANGELOG.md`, which excludes `lib/mix/tasks` entirely - so the task
cannot arrive through the Hex package. It presumably resolved while the dep
was a git pin under st-ADR-0061 and broke silently when the dep moved to
`{:statifier, "~> 2.0"}`. `gate.attest` therefore reported `attested: false`
on every run, including fully green ones, which blocked every unattended agent
commit in this repo (`ots-1fv`). Re-pointing it at the published `ex_quality`
task needs no dependency change.
