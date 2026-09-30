# Source review and leader-selected CI

The operator's policy in `docs/constitution.xml` owns this workflow. Work proceeds
in stacked PRs: the bottom targets main and later PRs target the preceding branch.
Review function, logic and code cleanliness independently; approve the current
head when no P0/P1/P2 issue remains and collect P3 findings for later. Ordinary
verdicts use `verdict: PASS|FAIL head: <40-hex SHA> by: <reviewer>` without a run ID.
Release verdicts also cite the completed successful full run. Current independent
approval, later blocking reviews, exact head and base changes remain admission
checks; land parents first and review the changed child diff before integration.

There is no automatic PR, push, tag or scheduled CI. For an explicitly selected
approved combination, use [the selection commands](../scripts/review/APPROVED-CI-SELECTION.md)
to prepare the candidate and receipt. Dispatch `leader-ci.yml` from main with the
exact candidate SHA, receipt and chosen scopes. Main's verifier rechecks source
approvals and reconstructs that candidate before build or test jobs begin.
Ordinary compile builds only `lib/masc.cmxa` for the stack bottom. Ordinary behavior
verification requires explicit suites. Every ordinary job includes setup within
its two-minute limit. A cold cache may prevent completion; incomplete or skipped
coverage is never a successful build or test result.

`ci.yml` and `test.yml` are reusable components. Full type checking, release
profile, dashboard, model checks, behavioral suites and distribution/installation
verification belong to `release-candidate.yml` at Release/Tag. Release publication
requires an explicit `publish=true` dispatch on an existing version tag and full
successful verification. Specialized host and packaging proofs remain manual.

A combined candidate receipt names that candidate and selected coverage. It does
not become an individual PR's check, an independent source approval or merge
permission. Ordinary review guards do not need a CI receipt; Release admission
still requires its current-head full verification evidence.

CI catches concrete functional, compilation, schema, credential or resource
failures. Bulk source-style lints, prose rules, byte inventories, historical counts
and recursive checks about other checks are not release gates. Feature work
continues while verification runs; agents do not watch, wait or repeatedly poll.
The disabled hosted workflows are not enabled by editing these source definitions.
