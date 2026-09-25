# Opentelemetry_statifier extension: /wurk:release

Additional required steps for `/wurk:release` in this repo. The skill reads
this file before step 1 of its `kind: "hex"` recipe and treats what is here as
required steps placed where this file says. Extensions add; they never
override, and nothing below rewrites a step the skill already performs.

Read this together with `.claude/wurk.json`'s `release` block. Between them
they name every file a release commit here touches, and no others.

The reference for every shape below is **the most recent release-prep commit
on `main`**, resolved when you read this rather than named here. Find it with:

```bash
git log --oneline --no-patch -L '/@version/,+1:mix.exs'
```

The first line is the last commit that moved `@version`, and the last commit
that moved `@version` is the last release prep by definition. Where this file
and that commit disagree, the commit is the evidence and this file is the
defect.

**This file names no SHA for that reference, on purpose.** A hard-coded
reference stops being the most recent the moment the next release lands: the
sentence that used to sit here named the 0.3.0 prep, and by the time anyone
read it again four later preps had landed behind its back (`ots-txv`). The
SHAs that remain below are historical claims - "this happened once, in that
commit" - and a historical claim does not go stale. Nothing here needs editing
at a release, and a release commit does not touch this file; the table at the
end lists every file it does touch, and this is not one of them.

## Why the recipe names no changelog

`kind: "hex"`'s changelog step renames a `## [Unreleased]` heading in one file
to `## [X.Y.Z] - YYYY-MM-DD`. This repo has no such heading and never will:
`changelog.mode` is `fragments`, and `CHANGELOG.md` says so in its own header -
unreleased work lives one file per bead in `changelog.d/`, and the fragments
are assembled into a version section at release. Pointing `release.changelog`
at `CHANGELOG.md` would make the skill's precondition read for an unreleased
section that is not there, and its edit rename a heading that does not exist.

So `release.changelog` is deliberately absent, and a recipe that does not name
a changelog names no changelog edit. The promotion this repo actually performs
is step B below - a required step, not an optional one. A release commit
without it is not a release commit.

The unreleased-work check the skill makes before anything else reads
`changelog.d/` here: if the directory holds no fragment other than its own
`README.md`, there is nothing to release, and the run stops exactly as it
would on an empty unreleased section. That is the directory's normal resting
state between releases (`.claude/wurk/commit.md` says the same), so a run that
stops there has found the expected condition, not a broken repo.

## Step A: the version carrier

**None.** `mix.exs`'s `@version` is the only place this package's version
string lives; `lib/`, `docs/` and `test/` carry no second copy, and `mix.exs`
derives `source_ref: "v#{@version}"` from the same attribute rather than
repeating it. There is no compiler-stamped version constant here of the kind
sibling packages carry, so the skill's own `version_file` edit is the whole of
the bump.

Stated explicitly so that a future release does not go looking for a carrier
that was never there. If one is ever added, it belongs in this section and in
the table below, in the same change that adds it.

## Step B: promote the changelog fragments

Placed where the skill's changelog step would have been, and modeled on the
most recent release-prep commit - the one the command at the top of this file
resolves, not a SHA written down here.

1. Read every `changelog.d/*.md` fragment except `README.md`. Each is a Keep a
   Changelog section heading followed by its bullets.
2. Insert a new `## [X.Y.Z] YYYY-MM-DD` section into `CHANGELOG.md` directly
   above the previous version's section. The heading form is the one the file
   already uses throughout - the bracketed version, a single
   space, then the date, **with no `-` separator between them**. (Keep a
   Changelog's own form has the dash; this file has never used it in any of
   its headings - read them with `grep '^## \[' CHANGELOG.md` - and a release
   is not the place to change them.)

   **The date is the LOCAL date of the machine cutting the prep**, the one
   `date +%F` prints there - not the UTC date, and not a date carried over
   from a campaign journal, which is written in UTC. The two differ for part
   of every day, and a section dated a day ahead of the commit that wrote it
   reads as a backdated release. Take the date from `date +%F` at the moment
   you write the heading (ruled by the operator, 2026-09-06). Sections
   already shipped are left as they stand: rewriting one to match a
   convention adopted after it was written loses the record of what the
   published section said.
3. Write a short lead paragraph between the heading and the first `### `
   sub-heading, saying what the release is. Unlike some sibling repos this is
   the **rule here, not the exception**: every released section in this file
   carries one, in the form `Minor release: <what changed>` or
   `Patch release: <what changed>` (the 0.3.0 prep `e502eab` wrote "Minor
   release: the bridge now covers the family sibling packages." - a
   historical example of the form, not the shape reference). Keep the
   reasoning for the version choice in the commit body, where every prep so
   far has put it.
4. Under the lead paragraph, write the fragments' bullets grouped by heading
   and ordered `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`,
   `Security`. **Carry every bullet over byte for byte.** The lead paragraph
   is the only prose written at release time; reordering, consolidating or
   rewording a fragment's bullet is an editorial pass a human does separately,
   before the release.
5. **No link reference.** Unlike sibling repos, this `CHANGELOG.md` has no
   link-reference block at the end of the file and no `[X.Y.Z]:` definitions
   anywhere - the bracketed versions in the headings are deliberately
   unlinked. Do not add one for the new version, and do not "repair" the file
   by adding the whole block.
6. Delete the promoted fragment files in the same commit. `README.md` stays.

Whether the release is major, minor or patch is not decided here - the version
is explicit input to the skill. The fragments' headings are evidence for that
judgement, not a rule that computes it.

## The README install pin

`release.readme_pin` is `true`. `README.md`'s `def deps` snippet carries a
`{:opentelemetry_statifier, "~> X.Y.0"}` pin - the exact-minor form, with the
patch component written as `.0` rather than dropped.

Three things about this pin that a release here has to know:

- **The form is `~> X.Y.0`, not `~> X.Y`.** The README's pre-1.0 banner
  recommends pinning to an exact minor, and the install snippet shows what it
  recommends. A prep writes the `.0` form; it does not "repair" the snippet
  back to the patch-dropped shape the skill's own step 2 assumes. The two
  forms admit the same patch releases (`~> 0.6.0` and `~> 0.6` both admit
  `0.6.1`), so nothing about the rule below changes with the form - only the
  string written. What differs is the minor bound, and that is what the `.0`
  is for: `~> X.Y` also admits `X.(Y+1).0` and every later minor below
  `(X+1).0.0`, while `~> X.Y.0` stops short of `X.(Y+1).0`.
- **The rule: a prep moves the pin to the minor being released.** A major or
  minor prep rewrites `~> X.Y.0` to the version it is cutting, again with the
  `.0`; a patch prep leaves it alone, because `~> X.Y.0` already admits the
  new patch. The skill's "check a previous release commit rather than
  inventing the format" step is satisfied by the resolved reference at the
  top of this file - and by this section, which states the form outright so
  that a prep reading a pre-`.0` commit does not copy the older shape.
- **The pin's current value is not written down here**, for the same reason
  no current version is. Read it and check it against the version file
  instead:

  ```bash
  grep 'opentelemetry_statifier, "~>' README.md   # the pin
  grep '@version "' mix.exs                       # the version it should track
  ```

  They should agree on major and minor. If they ever do not, the pin edit
  repairs the drift in one move rather than stepping one release at a time:
  it goes straight to the current major/minor, and that is the recipe
  working, not a mistake to correct back. That happened once - `bfd5cb5`, the
  0.1.0 Hex release prep, wrote `~> 0.1` when it added the Installation
  section and nothing touched it for three minors, until `c60fd25` (0.4.0)
  took it straight to `~> 0.4`.

## The files a release commit touches

Exactly these, and a release commit that touches anything else is wrong:

| File | Moved by |
|---|---|
| `mix.exs` | the recipe's `version_file` |
| `README.md` | the recipe's `readme_pin` |
| `CHANGELOG.md` | step B |
| `changelog.d/*.md` (deleted) | step B |

No `lib/` file appears in that table, and step A explains why.

## What a release here still is not

The skill does not tag, push, open a request or publish, and this extension
does not either. In this repo those are the operator's, in every campaign and
outside every campaign. `CLAUDE.md`'s authority table is explicit on both
halves:

- *a release (tag, `mix hex.publish`, GitHub release)* - trigger **never**,
  still unauthorized **always**: "publishing is the operator's, in every
  campaign".
- *a version bump on a release bead's branch* - allowed only on "an
  operator-authorized release bead, inside a campaign carrying the operator's
  explicit consent", and still unauthorized "on any other bead, on main, or
  when the operator has not named this repo's release bead".

So the one thing this recipe performs - the bump plus the step B promotion, on
a named release bead's branch, under a campaign consent that names it - is
release *prep*. `.claude/wurk/commit.md`'s version section records the same
boundary from the commit side: the version field moves only through a release
bead, never as a convenience.
