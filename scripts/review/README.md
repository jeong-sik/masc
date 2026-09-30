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
approved while its parent is still open. Land the parent first, then retarget
and inspect the changed diff before landing the child.

`merge-guard.sh --check --repo O/R --pr N --head SHA` checks current head,
independent trusted head-bound approval and the latest blocking reviews or
structured decision. It does not call Actions for an ordinary head. External
coding agents perform the actual merge with `gh pr merge --match-head-commit SHA`.

For a `release/vX.Y.Z` head, execute the full Release Candidate Verification
workflow explicitly. The release verdict also carries `run: <full run ID>`
between head and reviewer. Release admission requires the current full run,
including successful full-check, behavior, packaging and result jobs. A
missing or skipped required job is not evidence of full verification.

`queue-ledger.sh --repo O/R --format tsv` reports source-review readiness and
parent-first landing. It reads full CI evidence only for release heads.
`python3 scripts/review/test_source_review_policy.py` exercises live-boundary
controls in an isolated fake-GitHub fixture.
