# Combined-tree CI evidence

This is an opt-in implementation proposal for RFC-batch-validated-merge.
Code publication does not adopt an operational rule. The policy HOLD remains
until the separate amendment/adoption procedure completes. Coding-agent
sessions use read-only commands; only Keepers approve and merge.

## Evidence and the publication target

Every original member keeps a fixed head and review base, an independent
non-author `member-review: COMPLETE` of its full delta at that head, and no
later FAIL/HOLD or open change request. Member CI, PASS and approval are not
inferred from the ROLL run. The ROLL PR is the publication target and needs
its own successful required checks, PASS and independent head-bound approval.
Its run never becomes a member's run.

Publish the same line on ROLL and every member PR, then save it in a file:

```text
batch: PASS landing: ROLL roll: <ROLL40> base: <BASE40> run: <ROLL_RUN> members: <PR>@<HEAD40>,<PR>@<HEAD40> by: <KEEPER>
```

`landing: ROLL` is required. The grammar accepts full lowercase commit
identities and positive numeric IDs; duplicate members are refused. Member
order is tree reconstruction order. The run's PR and branch association must
identify one ROLL PR. Trusted repository participants publish the line, and
`by:` names a Keeper rather than the shared account login. Session independence
still requires the reviewer to know which session pushed the commit.

The ROLL PR body must also contain exactly one immutable input block:

```text
<!-- masc-roll-input-v1
{"base":"<BASE40>","members":[{"pr":1,"head":"<HEAD40>","review_base":"<REVIEW_BASE40>"}]}
-->
```

Use actual PR numbers and full commit IDs. Keep members in reconstruction order.
For the first member, `review_base` is the merge base of the fixed ROLL base
and that member head; for a stacked child it is the reviewed parent base.
`python3 scripts/review/roll_input.py --body-file <saved-ROLL-body>` validates
the block and prints its digest. The cited ROLL Actions run must upload an
artifact named `roll-evidence` containing `roll-evidence.json`; the guard
compares its input digest, tested checkout parents/tree, run identity and
executed suite set with the fixed body and current ROLL head. The CI producer
owns this receipt. An absent or mismatched receipt refuses publication.

## Read-only preparation

```sh
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
bash scripts/review/land-batch.sh --repo "$REPO" --git-dir "$PWD" \
  --batch /path/to/batch.txt --check-only
```

`approve-guard.sh --batch FILE` supports member and ROLL approval. Its first
verdict line and final guard footer retain the ordinary binding. Both
`merge-guard.sh --batch FILE --check` and actual publication accept only ROLL;
a member cannot be individually merged using the batch evidence.

Without `--batch`, the per-PR path is unchanged. The queue ledger remains
conservative and does not infer batches from titles or labels.

## What the guard proves

- Each member retains a fixed head and independent full-delta source review.
  An open CR or a later FAIL/HOLD blocks publication. The ROLL head supplies
  the current checks, PASS, and bound approval.
- Git reconstructs BASE plus all ordered member heads and compares the full
  tree with ROLL. Temporary Git objects do not change a checkout or branch.
- Main changes after BASE avoid the union of member-applied paths and shared
  inputs. A path restored by a later member remains in that union. The final
  tree preserves only those admitted external changes.
- After the last expensive checks and mutable identity/verdict reads, the
  guard rechecks each member's source review and refusal state, plus the
  ROLL's independent footer-bound approval. A dismissed or missing ROLL
  approval refuses publication.
- One invocation submits at most one head-pinned squash request, targeting
  ROLL. No A, A+B or other intermediate member tree is written to main.
- Arrival proof checks the API merge commit in main's first-parent history,
  its single parent, and its complete tree against ROLL applied to that parent.
  An immediately completed request also checks the parent against the main
  observed before invoking the merge guard.

The implementation uses Git's
[merge-tree](https://git-scm.com/docs/git-merge-tree) operation and GitHub's
[workflow-run identities](https://docs.github.com/en/rest/actions/workflow-runs).

## Pending requests, receipts and original PRs

A Keeper uses the same command without `--check-only`. If the request remains
pending after one read, exit 7 names ROLL. Resume at the next work boundary.
There are no sleeps, CI dispatches, polling loops or automatic PR closures.
A still-open ROLL may receive the same pinned request again on a later
invocation. There is no cross-invocation exactly-once request guarantee.

A merged ROLL is audited through `land-batch.sh` without submitting another merge.
A concrete member passed to `ci-freshness.py --batch` after publication refuses
with code 6 (the ledger reports unknown freshness); it cannot authorize a new
approval or be mistaken for an arrival audit. Only verified
arrival produces `absorption_candidates`. A Keeper separately records the
mapping from original head/review evidence to the ROLL run and arrival
commit, then closes the original PRs as absorbed. They are not reported as
individually merged. Already closed originals need no repeated metadata action.

The read-only `approve-guard.sh --merge-check --receipt-json` option returns
verified approval IDs and their head. Default output remains text. The landing
command retains these IDs as `preflight_observation`, explicitly captured
**before merge-guard**, not at its final write boundary. Save that receipt when
recording pending work. On a merged resume, `tree` describes the proven squash
landing; `main` is the current observed tip and `post_landing_commits` lists its
later first-parent commits. Later edits do not become pre-landing conflicts or
alter that historical tree proof. A merged resume cannot reconstruct past approvals from
current API state: its historical approval mapping is marked unavailable
without the saved preflight receipt. Current member head/review and actual Git
arrival proof remain separately reported.

## Limits and refusal codes

- Head changes require a new batch, including a clean main-only merge. This
  implementation has no head-equivalence exception.
- All required ROLL checks must succeed. Budget exhaustion is ROLL failure; a targeted
  supplemental run cannot waive it. There is no arbitrary member-count cap.
- GitHub's separate API reads and merge request have no combined
  checks/approvals/main CAS. Final reads reduce the race; they cannot eliminate
  it. An unexpected parent or tree stops the operation without closing members
  or automatically reverting the published commit.
- The historical seven rollups and 25 sequential member landings are not
  measurements of this ROLL publication path. Fixtures do not measure saved
  runner time or production merge latency.

Exit codes: 0 checked/published; 1 infrastructure; 2 invalid input; 3 ROLL
checks/review; 4 landing tree/parent; 5 external main inputs; 6 member or
approval evidence; 7 asynchronous request pending.

## Local verification without builds

```sh
python3 scripts/review/test_batch_evidence.py
bash scripts/review/approve-guard-selftest.sh
```

The fixtures use real disposable Git histories and fake GitHub responses.
They include three members where A/B/C and A+B+C pass but A+B fails, one ROLL
write, pending/resumed arrival, late approval dismissal, red ROLL refusal,
wrong parent/tree/history, strict frozen heads, and unchanged nonbatch gates.
No test performs a live approval or merge.
