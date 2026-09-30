# Review first, leader-selected CI

Code review and current-head source approval precede CI. The MASC leader
chooses approved PRs, prepares a combined candidate, and explicitly selects
its CI coverage. PR creation, push, Ready transitions, approval, tags and
schedules do not automatically start CI. No daily report schedule is added.

Use [the selection commands](../scripts/review/APPROVED-CI-SELECTION.md) to
prepare a candidate and its receipt. Dispatch `leader-ci.yml` from main with
the exact candidate SHA, receipt and chosen scopes. The main workflow checks
current approvals and reconstructs the candidate before any selected build
or test job starts. Ordinary choices are the bottom Core build and explicit
minimal behavior suites. Each job includes setup in its two-minute limit;
empty behavior selection is refused. Full type checking, release profile,
dashboard, TLA, lint and full behavior verification belong to the existing
Release/Tag workflow.

`ci.yml` and `test.yml` are reusable components. Specialized host proofs and
packaging remain manual. `release-candidate.yml` requires a release branch or
version tag and performs full checks, behavior and installation verification.
Release publication additionally requires an explicit `publish=true` dispatch
on an existing version tag. Tests not selected are not recorded as successful.

CI results describe the combined candidate and selected coverage. They are
separate from source approval and do not automatically authorize merge. The
existing PR-check evidence reader and merge guard do not accept leader CI
receipts; do not bypass them or claim a candidate run is an individual PR's
check. Their receipt integration is a separate change.

Feature work continues while selected verification runs. Agents do not watch,
wait or poll CI. Workflow definitions remain disabled in GitHub until the
manual definitions are integrated and the leader enables the chosen entrypoint.
