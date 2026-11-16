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
