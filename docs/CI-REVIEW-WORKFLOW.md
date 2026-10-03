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

There is no automatic PR, push or tag CI. The operator-authorized
`main-minimal-build.yml` checks main at minutes 7 and 37: it builds the server,
TUI, browser host and deployment preflight executables in one Dune invocation.
Successful non-documentation input fingerprints skip toolchain setup and build;
the summary names the actual previously built SHA, and a skip is not compilation
evidence for a newer SHA. Existing opam caching and a shared Dune cache reduce
repeated work. Builds are serialized without cancelling the active build.
Scheduling may be delayed; this does not guarantee a build within 30 minutes.
This observation does not approve a PR or replace full Release/Tag checks.

For an explicitly selected
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
uses `release.yml` with an existing version tag, `rc_run_id`, and explicit
`publish=true`. The tagged commit must match the latest successful full RC.
The publication job verifies its receipt and artifact checksums and uploads the
existing distribution; it does not rebuild or rerun tests. A publication run is
not full verification evidence for approval or merge. Development and release-profile OCaml type checks share
one toolchain job; node behavior runs under the behavior lane's root `@runtest`. Dune's exit status is the behavior verdict;
there is no known-failure exemption list or second standalone compilation pass.
The behavior lane runs product suites, without CI/review/PTY-helper self-tests.
Presentation tools are installed only for the behavior lane. The dashboard is
built once with the production configuration and shared by all native targets;
type checks and dashboard payload-consumer tests stay in their own job. That
job exercises Goal, schedule, turn-record, verification, portrait, lifecycle and
memory behavior directly; test selection does not scan backend source strings.
Installer script tests run once on Linux in the distribution
job and once on macOS with stock Bash and BSD utilities;
each of the four native targets still builds and verifies its shipped binaries
and installation. Native files are uploaded after installation validation;
early unverified duplicates and the separate fixture-preview bundle are omitted.
The behavior lane builds its own sandbox image where it is used.
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

To publish a verified candidate after creating its version tag, use the same
commit's completed full RC run:

```bash
gh workflow run release.yml --ref vX.Y.Z -f rc_run_id=RUN_ID -f publish=true
```

The current-attempt receipt and the run's assembled distribution must remain
available. A failed-job rerun can reuse installation artifacts from an earlier
successful job in the same run. The exact RC-checked release body travels with
the receipt and is not regenerated at publication. Missing or expired artifacts require another RC; rebuilding inside the
publication job would no longer publish the bytes that were verified.
