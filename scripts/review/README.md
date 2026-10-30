# Stack review admission

Review ordinary stacks from source. No automatic CI and no CI-run identifier
is needed for approval. Review function, logic and code cleanliness; approve
when P0/P1/P2 are resolved, retain P3 for later cleanup.

The reviewer writes a literal first line:

```
verdict: PASS head: <40-hex SHA> by: <reviewer>
```

Capture the base commit and complete change identity when reviewing, before
writing the approval. Use exact PR `base.sha` and `head.sha` from GitHub:

```sh
python3 scripts/review/review-diff.py --repo O/R --base BASE_SHA --head HEAD_SHA
bash scripts/review/approve-guard.sh --repo O/R --pr N --head HEAD_SHA \
  --review-base BASE_SHA --review-diff CAPTURED_SHA256 --body FILE
```

The identity covers each changed path, old/new mode and complete old/new object
ID against GitHub's three-dot merge base. It includes binary and submodule
changes, independent of rename guesses, patch truncation and local diff order.
It needs a Git checkout; `GUARD_REPO_ROOT` selects one when the script is
executed outside that checkout. Missing exact objects are fetched from the
named repository; unreadable evidence refuses admission.

The reviewer supplies the captured identity explicitly. The guard does not
stamp a current diff onto an old source review. New approval footers preserve
the reviewed base and identity. Consumption compares the current complete
change: a moved/renamed base with identical change keeps the approval; retarget
or parent landing that changes the diff requires independent re-review.
Head-only approvals supply no evidence of the reviewed diff and are not
backfilled. Use `--check` for a read-only admission probe. A source-reviewed child may be
approved while its parent is still open. Inspect the REST PR's `stack` metadata
and ordered stack membership before choosing the merge scope. **Merge a native
stack whole, once, through its top PR; never merge it layer by layer from the
bottom.** Do not require separate parent merges or manually retarget it. For a confirmed
non-native branch chain, land the parent first and inspect the changed diff
before landing the child. See the [Native GitHub Stacks guide](../../docs/guides/NATIVE-GITHUB-STACKS.md).

Approval publication records the reviewing account's independent conclusion.
Existing change requests and structured decisions do not prevent a new,
independently reviewed PASS from being recorded. They still apply when a merge
or source receipt consumes review evidence. API-read failures, author exclusion,
reviewed head/base/diff checks and Release CI requirements remain enforced.
Ordinary source publication does not wait for a `leader-selected-ci` pin; merge
admission still checks that pin.

To replace your own open change request after rereview, pass
`--replace-own-cr REVIEW_ID` alongside the reviewed base, diff and PASS body.
The ID may name any of your open CRs on that PR; repeat the option to name
several. Every ID is checked against the authenticated account, actual CR state,
and matching claimed Keeper; a different or missing claim remains unresolved.
Each Keeper can replace their own requests separately; other unresolved requests
continue to block receipt and merge. Replacement flags cannot authorize merge or
receipts by themselves. Claimed names do not authenticate Keeper sessions.
Review IDs do not establish publication order: the guard compares submission
times when choosing the latest formal review and when validating a replacement.
Missing times or ties for an account's latest formal review refuse ordering.
An older tie is allowed, but an approval must be strictly later than the request
it replaces; a same-time approval cannot clear it.

`review-decisions.py` reduces structured review/comment decisions independently
for each authenticated GitHub login. A later trusted PASS can supersede only
that account's older decisions. A PR-author or unrelated account's PASS comment
cannot clear another account's FAIL/HOLD. Keeper `by:` names are diagnostic;
Keepers sharing a GitHub login do not supply independent formal opinions.
Unidentified decisions cannot grant PASS, and unpublished PENDING reviews do
not participate. Positive comment edits cannot move an old PASS past a later
refusal; negative edits and contradictory same-timestamp decisions still block.

`merge-guard.sh --check --repo O/R --pr N --head SHA` checks each included
PR's current head, independent trusted head-bound approval and latest blocking
reviews or structured decision. It rechecks stack membership and included
head/base identities before admission. Check output names the validated
merge target: a native stack can land into another feature branch, whose PR
is outside this stack scope. That is not main integration. For an ordinary head
it additionally reads the merge-compile verdict — target freshness plus the
commit status — as advisory `ADVISORY #N: ...` lines, and never dispatches CI
itself. External coding agents use this read-only check before submitting a native
stack via `PUT /repos/O/R/pulls/TOP_PR/merge-async`; for a non-native PR, use
`gh pr merge --match-head-commit SHA`. The asynchronous receipt labels only the preflight target, since GitHub accepts
only the selected head SHA as a precondition; its accepted destination remains
unconfirmed until the result is read. The receipt is acceptance,
not completion: confirm the result and each included PR's merged state before
reporting success. The guide above documents the request and its SHA boundary.

For a `release/vX.Y.Z` head, execute the full Release Candidate Verification
workflow explicitly. The release verdict also carries `run: <full run ID>`
between head and reviewer. Release admission requires the current full run,
including successful full-check, behavior, packaging and result jobs. A
missing or skipped required job is not evidence of full verification.

`queue-ledger.sh --repo O/R --format tsv` reports source-review readiness and
native stack scope admission or non-native parent waits. It reads full CI
evidence only for release heads. Structured blockers name their authenticated
account, record ID and decision timestamp. Other admission failures retain their
concrete guard diagnostic instead of being collapsed to `review`.

## Assigning the next review

`review-worklist.py` reads every open PR, every page of its reviews and issue
comments, and the commit comparison for its exact base and head. It keeps
GitHub's user/team requests and proposes missing requests across an explicit
pool of GitHub logins:

```bash
python3 scripts/review/review-worklist.py --repo OWNER/REPO \
  --reviewer LOGIN_A --reviewer LOGIN_B
# Publish missing requests and read them back:
python3 scripts/review/review-worklist.py --repo OWNER/REPO \
  --reviewer LOGIN_A --reviewer LOGIN_B --request
```

The default is read-only. New PRs are distributed oldest first by outstanding
and proposed requests. Changed-head CRs return to each actual account owner;
same-head CRs wait for author action unless an explicit rereview request exists.
Shared logins count once. COMMENT/PENDING does not establish approval. Existing
approval evidence uses the complete-diff/scope guard before being admitted.
Proposed reviewers must have a different GitHub user ID from the PR author and
every linked author or committer in the comparison. The tool resolves reviewer
logins to IDs, repeats that lookup immediately before a request, and checks the
returned request IDs. An incomplete comparison or an unlinked commit identity
stops new proposals for that PR. The same account check also
applies to approval receipts used by this worklist; it does not prove that the
reviewer's actual session was independent. Existing conflicting requests and
CR ownership remain visible and untouched; when appropriate a separate
independent reviewer is proposed. Existing team requests are preserved without
assuming their membership. A separately validated current independent source
approval avoids a redundant extra request even if another account's CR remains
open; this does not clear the CR or grant merge admission. Release decisions
still use their own CI policy.

Assignments mean requested, not running or reviewed. Each action retains its
head/base/stack identity. Before posting, the tool rereads PR/evidence and skips
changed snapshots, including changed commit-account links. Receipt scope and
policy must match the observed PR, and a source admission is rechecked against
PR scope and commit identities. Requests and these observations cannot be made
atomic with a SHA or an account mapping. After a POST
it reads scope/requests back and reports races or uncertainty without blindly
retrying. Existing requests are never removed; a transport/read failure stops
further notifications and preserves earlier receipts. No timer, daemon, lease,
CI dispatch or review approval is added.

Keeper selection follows [review routing](../../config/prompts/pr-review-routing.md).
Repository defaults do not update running Keeper instructions; apply those
separately through supported Keeper configuration and read them back. Offline
feature checks: `test_review_routing.py` and `test_review_worklist.py`.

## Reading a refusal

When a non-author APPROVED review exists but is not admitted, the
`no trusted non-author approval bound to this head and complete diff` refusal
(from `approve-guard.sh --merge-check`, and so from `merge-guard.sh`) lists,
per review, which test failed (author association, first-line verdict,
footer prefix, `reviewed base`/`diff sha256` tail, a stale diff hash, or the
`review-scope` stamp) and prints the exact last line to copy. `review-refusal.py`
makes the admission decision and the reasons come from the same code, so the
guard and the explanation cannot disagree.

Offline checks: `python3 -I scripts/review/test_review_decisions.py`,
`python3 -I scripts/review/test_review_refusal.py`,
`python3 -I scripts/review/test_approve_guard_refusal.py`,
`python3 -I scripts/review/test_queue_ledger.py` and
`python3 -I scripts/review/test_stack_scope.py`.

## Preparing an approved candidate

`prepare-approved-batch.py` combines explicitly selected, directly main-based
ordinary heads without dispatching CI. In addition to current-head source
approval, it requires the approval's `review-scope` receipt stamped by
`approve-guard.sh`: reviewed base ref/SHA and native stack identity/position.
Retargeting or changing the diff boundary requires a fresh independent review;
unrelated main advancement with the same merge-base does not. Older approvals
without this receipt need reapproval before candidate composition. This does
not add a CI requirement or change ordinary merge admission.

Missing Git objects are fetched from the API-resolved `--repo` repository,
independently of the checkout's origin. Receipt publication includes flush and
close in its rollback boundary. On failure it removes the incomplete receipt
and deletes only a candidate ref still pointing to the commit it created.

Ordinary merge admission and candidate preparation share `review-scope.py`: approvals require the same base ref and native stack position, and either the exact reviewed base SHA or the same merge-base with the reviewed head. Missing or changed diff scope requires a fresh independent approval; unrelated base advancement remains admissible.
