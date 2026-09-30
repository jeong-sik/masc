# Combined-tree CI evidence

This is an opt-in implementation proposal for RFC-batch-validated-merge.
Code publication does not adopt an operational rule. The policy HOLD remains
until the separate amendment/adoption procedure completes. Coding-agent
sessions use read-only batch landing commands. Independent review sessions may
approve through approve-guard; batch publication remains a Keeper operation.

## Evidence and the publication target

Every original member keeps its own exact head, successful PR-check run,
current PASS and independent head-bound approval. The ROLL PR is the actual
publication target and needs its own five successful checks, PASS and
independent approval. Its run never becomes a member's run.

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

## Read-only preparation

```sh
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
bash scripts/review/land-batch.sh --repo "$REPO" --git-dir "$PWD" \
  --batch /path/to/batch.txt --check-only
```

`approve-guard.sh --batch FILE` records the batch line with a member or ROLL
source approval. The first line is `review: APPROVE head: <HEAD40> by: <KEEPER>`;
the final guard footer binds the same head. This review does not validate CI or
combined freshness. `approve-guard.sh --integration-check --batch FILE` performs
the separate CI/freshness preflight. Both
`merge-guard.sh --batch FILE --check` and actual publication accept only ROLL;
a member cannot be individually merged using the batch evidence.

Without `--batch`, the per-PR path is unchanged. The queue ledger remains
conservative and does not infer batches from titles or labels.

## What the guard proves

- Every member head and the ROLL head have their own successful current checks
  and PASS. An open CR or a later FAIL/HOLD blocks publication.
- Git reconstructs BASE plus all ordered member heads and compares the full
  tree with ROLL. Temporary Git objects do not change a checkout or branch.
- Main changes after BASE avoid the union of member-applied paths and shared
  inputs. A path restored by a later member remains in that union. The final
  tree preserves only those admitted external changes.
- After the last expensive checks and mutable identity/verdict reads, the
  guard rechecks every member and ROLL's independent footer-bound approval.
  A dismissed or missing approval refuses publication.
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
integration admission or be mistaken for an arrival audit. Only verified
arrival produces `absorption_candidates`. A Keeper separately records the
mapping from original head/run/approval evidence to ROLL run and arrival
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
without the saved preflight receipt. Current member head/run and actual Git
arrival proof remain separately reported.

## Limits and refusal codes

- Head changes require a new batch, including a clean main-only merge. This
  implementation has no head-equivalence exception.
- All five checks must succeed. Budget exhaustion is ROLL failure; a targeted
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
