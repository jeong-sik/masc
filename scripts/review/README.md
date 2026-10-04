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
and ordered stack membership before choosing the merge scope. For a native
stack, merging a selected PR includes every open downstack PR through it; do
not require separate parent merges or manually retarget it. For a confirmed
non-native branch chain, land the parent first and inspect the changed diff
before landing the child. See the [Native GitHub Stacks guide](../../docs/guides/NATIVE-GITHUB-STACKS.md).

`merge-guard.sh --check --repo O/R --pr N --head SHA` checks each included
PR's current head, independent trusted head-bound approval and latest blocking
reviews or structured decision. It rechecks stack membership and included
head/base identities before admission. Check output names the validated
merge target: a native stack can land into another feature branch, whose PR
is outside this stack scope. That is not main integration. It does not call Actions
for an ordinary head. External coding agents use this read-only check before submitting a native
stack via `PUT /repos/O/R/pulls/N/merge-async`; for a non-native PR, use
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
evidence only for release heads.

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
