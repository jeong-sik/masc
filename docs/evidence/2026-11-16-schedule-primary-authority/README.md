# Schedule primary authority: source candidate

Date: 2026-11-16. Source review, not executed recovery evidence.

- Base: `85f2823f053a693cecc8b63d6d0cb460dd10f9d0`.
- Implementation: `921754a8947c89fc78ddb9992abd88c09d994c66`.
- Reviewed seven-file diff SHA-256 (`git diff` before commit):
  `c39f7fb85718d9e8498f9d267aedc497d3b30d3ce7d21245d1f558a838b51447`.
- Independent review: Codex subagent `continuity_audit`, which did not edit the
  candidate, found no P0/P1/P2 issue. This is not a GitHub approval or evidence
  of a second model/account.
- `git diff --check`: passed.
- Six modified OCaml files parsed with `ocamlc -stop-after parsing -c`: passed.
  The available compiler was 5.5.1; the repository pins 5.5.2. Syntax only:
  no typecheck, linking, Dune or behavior suite ran.

## Boundary and intended verification

`Schedule_store.load_for_mutation` accepts primary authority or an uninitialized
store. A recovery mirror produces `Primary_ledger_unavailable`, preserving
missing/unreadable cause. `read_state_observed` still returns the mirror with
provenance. Primary commits remain successful if a later mirror write fails.

| Source → consumer | Added behavioral assertion | Execution |
| --- | --- | --- |
| Store → nine mutation entrypoints | Missing/corrupt primary never promotes a stale Scheduled mirror; bytes unchanged | Not run |
| Store → startup recovery | Stale Running mirror cannot revive a settled wake | Not run |
| Store → runner tick | Cancelled/completed primary × missing/corrupt primary produces no dispatch or new signal | Not run |
| Restored authority → runner | Original terminal work stays terminal | Not run |

Existing fresh-store, mirror-write-failure and attempt-authority cases remain.
They have not been re-executed for this candidate. After publication, the selected
behavior command is:

```sh
gh workflow run test.yml --ref fix/farm-schedule-authority-20261116 \
  -f suite=test_schedule_store,test_schedule_runner -f minimal=true
```

This command has **not** been dispatched. A run must identify its actual head,
ref, suites and conclusion before it becomes evidence. Ordinary source review
does not require waiting for CI. This record establishes no Release/Tag,
installation, live operation, dashboard or multi-Keeper scale result.

## Remote and publication boundary

GitHub connector main observation: `0c875447ee7273da2d911d16e340410855b24885`.
All seven original files have the same Git blob at that head and the local base.
This establishes patch-source overlap, not equality of complete bases or
unmodified dependencies. Local fetch/API communication was unavailable.
Re-read remote main and reviews before publishing or integrating.

Local native stack: `fix/farm-schedule-authority-20261116` followed by
`docs/farm-authority-audit-20261116`. Publication, PR-number changelog fragments,
GitHub reviews, behavior execution and deployment remain outstanding.
`gh stack submit --auto` was attempted and exited 4 before publication:
`authentication token not found for host github.com`. `gh auth status` also
could not validate the active account. Connector access does not supply the
local native-stack CLI with credentials; no standalone PR was substituted.
See the [Farm follow-up report](../../reports/2026-11-16-farm-storage-and-input-audit.md)
for the broader product scope.


## 2026-11-16 integration and executed component proof

The whole native stack was rebased onto
`e0e819e29968366c1dffb59ad625ba4e17d4ac22`. The rebased source head is
`236754fcfb72f49ef9c365465dfd1e63cf3e6010`; its documentation parent for this
new test layer is `8d4a43c0f7832ef93d64eaaa165293db032efb1d`.
Both old patches are unchanged in range-diff and all nine candidate files
match the old reviewed bytes. Independent changed-base source review by
`continuity_audit` found no actionable P0/P1/P2 after reading current backend,
locking and direct-consumer changes. This is not a GitHub approval.

This layer adds `test_schedule_authority`, using the actual FileSystem backend,
public workspace config, store, service and runner. Eleven cases passed,
including six real self-exec child reopenings. The cases cover missing/corrupt
primary state with stale Scheduled or Running mirrors, cancellation/settlement,
mutation refusal, service callback ordering, unchanged mirror bytes and signal
rows, and restored terminal authority. A genuinely fresh store remains writable.
The service withdrawal assertion belongs to `Schedule_service.cancel`; it does
not cover the server's separate `cancel_keeper_schedules` purge choreography.

The standalone receipt is retained under this worktree's ignored
`artifacts/farm-schedule-behavior-20261116/`. Its fixed product snapshot is
`8d4a43c0`, with 273 source inputs and generated Embedded_config from 430 committed
config assets. The two promoted test/stanza files match draft manifest
`76c5fc07e54a6694605523a49988a5773c19f6b822861fd2dae91cb649367954`.
Compiler/environment probes were captured before compilation. The final run-3
records six successful commands and eleven passing cases; it reused verified
compiled inputs and rebuilt the changed test. Result SHA-256:
`4b1dbab944c2ae327c981c8f43f47da0ea05546159f52cf7bea3e0d9e034264e`.

Earlier attempts are preserved: run-1 omitted the actual stage_flock C stub
from the standalone link; run-2 reached successful child assertions but failed
when the parent's waitpid was interrupted. The final fixture retries waiting
for that same child on EINTR; it does not replay a process or store operation.

This does not execute the whole existing store/runner suites, Memory backend,
Keeper teardown/queue/provider integration, crash-mid-write scenarios, full
Dune graph or a deployed server. The earlier syntax-only and unrun-suite rows
remain historical evidence. No CI, remote submission, merge, installation or
original operational recovery is established here.
