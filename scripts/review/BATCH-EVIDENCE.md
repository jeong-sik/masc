# Combined-tree CI evidence

This is an opt-in implementation proposal for RFC-batch-validated-merge.
Publishing or merging this code does not adopt a world-constitution article.
Keepers must complete the amendment/adoption procedure before using this path
to replace the ordinary main-overlap condition. Coding-agent sessions use the
read-only commands below; only Keepers approve and merge.

## Evidence

Each member keeps its own successful PR-check run, exact-head PASS and
independent head-bound approval. A rollup run never becomes a member's run.
The CI-only rollup PR remains open until the final arrival audit completes.
Publish the same line on that PR and every member PR, then save it in a file:

```text
batch: PASS roll: <ROLL40> base: <BASE40> run: <ROLL_RUN> members: <PR>@<HEAD40>,<PR>@<HEAD40> by: <KEEPER>
```

The grammar accepts full lowercase commit identities and positive numeric
IDs. Member order is landing order; duplicate members are refused. The line
must be present in comments from trusted repository participants. `by:` names
a Keeper, as with ordinary verdicts, and must not be that account's login.
Session independence remains the reviewer's responsibility: a shared GitHub
account cannot prove which session pushed a commit.

## Read-only preparation

```sh
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
bash scripts/review/land-batch.sh --repo "$REPO" --git-dir "$PWD" \
  --batch /path/to/batch.txt --check-only
```

`approve-guard.sh` and `merge-guard.sh` accept `--batch FILE`. The approval
guard inserts the verified batch line between the existing member verdict and
guard footer. Without that option, the existing per-PR path is unchanged.
The queue ledger keeps its ordinary conservative freshness classification; it
does not discover batches or infer membership from labels or PR titles.

## What the guard proves

- ROLL belongs to the cited CI-only PR, and its current PR-check plus all five
  required jobs succeeded. Each open member independently meets the same CI
  gate and retains its own current PASS; open change requests block the batch.
- Git reconstructs BASE plus the ordered member heads with `merge-tree` and
  compares the complete resulting tree with ROLL. It creates temporary Git
  objects with `commit-tree`; it never edits a checkout, index or branch.
- Only a prefix of members may already be merged. GitHub's exact member merge
  identities must occur in main's first-parent history after BASE. Each such
  landing must match a recomputed merge tree, including blob modes/deletions.
- Every other main commit must avoid roll files and declared shared inputs.
  The remaining members are reapplied to current main; the final tree may
  differ from ROLL only by those admitted, unchanged nonmember paths.
- All remaining members need independent head-bound approval before a write.
  The existing guard still pins each write to the member's head. The landing
  wrapper checks its actual parent and resulting tree after each write and
  performs a final complete arrival audit.

The implementation uses Git's documented
[merge-tree](https://git-scm.com/docs/git-merge-tree) operation and GitHub's
[workflow-run identities](https://docs.github.com/en/rest/actions/workflow-runs).

## Execution and limits

A Keeper uses the same landing command without `--check-only`. If an
asynchronous merge remains pending after one read, the command returns exit 7
with the submitted member identity. Resume the same immutable batch at the
next work boundary. There are no dispatches, sleeps, retry loops or CI polls.
The CI-only PR is closed separately after the final audit succeeds.

- **Head changes require a new cut.** This version deliberately requires exact
  manifest heads, including after a clean main-only merge; it does not infer
  the RFC's historical remerge/patch-equivalence exception.
- **All five checks must succeed.** A budget-exhausted red ROLL cannot be
  supplemented into success by this implementation. Current edited-tests code
  returns failure when its budget leaves suites unrun. The RFC's r1d example
  and supplemental-run path need a separately reviewed coverage contract;
  this implementation grants no such exception. Use a smaller batch that
  completes the checks.
- **GitHub has no expected-main CAS.** Final CI, review and main reads narrow
  races but are not a transaction. An unexpected merge parent or tree stops
  further writes; the command never silently retries or reverts a merge.
- The current API cannot prove the original session identity or reconstruct
  missing historical approvals. Unknown evidence refuses. No claim is made
  that fixture success measures saved runner minutes or merge latency.

## Local verification without builds

```sh
python3 scripts/review/test_batch_evidence.py
bash scripts/review/approve-guard-selftest.sh
```

The batch suite uses real disposable Git histories and a fake GitHub API. It
checks reuse after the first member lands, combined-tree mismatch, wrong or
failed runs, changed heads, external main overlap/shared inputs, missing
history and decisions that change during validation. No test performs a live
approval or merge.
