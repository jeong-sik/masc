# Source review and leader-selected CI

The operator's policy in `docs/constitution.xml` owns this workflow. Work proceeds
in stacked PRs: each later PR targets the preceding branch. Native Stack metadata
names the trunk and the included parents.
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
verification requires explicit suites. Prefer short, lightweight checks; about
two minutes is an example of their size, not a fixed cap, job timeout or pass/fail
boundary. Existing stalled-job and runner hang guards are separate resource
safeguards. Incomplete or skipped coverage is never a successful build or test
result.

Native GitHub Stacks use REST `stack` metadata and the [stack workflow](guides/NATIVE-GITHUB-STACKS.md). The asynchronous merge endpoint includes all open downstack PRs through the selected PR. Inspect and approve every included head; do not treat a non-main direct base as a blocker or manually retarget a native stack. A leaf source-review PASS does not certify its downstack.

`pr-check.yml` offers optional explicit `workflow_dispatch` source/config syntax
and committed-credential checks. It has no PR, push or scheduled trigger and does
not compile the Core library or run behavior suites. Request it deliberately
when that coverage is needed; it is separate from leader-selected candidate
verification and does not grant merge permission.

`ci.yml` and `test.yml` are reusable components. Full type checking, release
profile, dashboard, behavioral suites and distribution/installation
verification belong to `release-candidate.yml` at Release/Tag. Release publication
requires an explicit `publish=true` dispatch on an existing version tag and full
successful verification. Development and release-profile OCaml type checks share
one toolchain job. Installer script tests run once on Linux in the distribution
job and once on macOS with stock Bash and BSD utilities;
each of the four native targets still builds and verifies its shipped binaries
and installation. The behavior lane builds its own sandbox image where it is used.
TLA model checks run explicitly through `model-check.yml` when state-machine
specifications change; they are not a prerequisite for shipping a binary.
Specialized host and packaging proofs remain manual.

Prefer short, focused checks: the constitution's "about two minutes"
describes their intended scale, not a timeout or a pass/fail threshold.
Only an actual successful completion is build evidence.

A combined candidate receipt names that candidate and selected coverage. It does
not become an individual PR's check, an independent source approval or merge
permission. Ordinary review guards do not need a CI receipt; Release admission
still requires its current-head full verification evidence.

CI catches concrete functional, compilation, schema, credential or resource
failures. Bulk source-style lints, prose rules, byte inventories, historical counts
and recursive checks about other checks are not release gates. Feature work
continues while verification runs; agents do not watch, wait or repeatedly poll.
The disabled hosted workflows are not enabled by editing these source definitions.
