# Quality configuration for opentelemetry_statifier.
#
#   mix quality                 - full gate: format, compile, credo, dialyzer,
#                                 deps audit, full test suite with coverage.
#                                 Run before every commit.
#
#   mix quality --profile loop  - inner loop while implementing: skips dialyzer
#                                 and coverage, runs only the tests covering
#                                 changed code. Use between edits.
#
# Agents: prefer `--format json --report -` when you want to route on results.
#
# Deliberately smaller than statifier-ex's gate. That repo's custom stages -
# the gate guard, the ADR guard and judge, the regression ratchet - all exist
# to protect a conformance corpus and an accepted ADR set this package does
# not have. Adopting any of them here is a decision to record when there is
# something for it to protect, not a default to inherit.
#
# There is deliberately no .credo.exs either: credo's own defaults under
# --strict are the gate until this package has a reason to deviate from one.

[
  format: [
    check: true
  ],
  compile: [
    warnings_as_errors: true
  ],
  credo: [
    strict: true
  ],
  # The two docs stages make this gate the pre-publish check for the
  # package's HexDocs and hex.pm pages. The Docs stage fails on any ExDoc
  # warning. The doc_links stage fails on the link rules ExDoc accepts
  # silently: a README relative link not in the package files, a relative
  # link in a Markdown extra to a file that is not itself an extra (moduledoc
  # links are the Docs stage's), two extras sharing a basename, a silent
  # rewrite to a different extra.
  docs: [
    enabled: :auto
  ],
  doc_links: [
    enabled: :auto
  ],
  profiles: [
    loop: [
      stages: [:format, :compile, :credo, :test],
      test: [scope: :changed, coverage: false]
    ]
  ]
]
