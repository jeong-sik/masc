# Stack review admission

Review ordinary stacks from source. No automatic CI and no CI-run identifier
is needed for approval. Review function, logic and code cleanliness; approve
when P0/P1/P2 are resolved, retain P3 for later cleanup.

The reviewer writes a literal first line:

```
verdict: PASS head: <40-hex SHA> by: <reviewer>
```

Approve with `approve-guard.sh --repo O/R --pr N --head SHA --body FILE`.
Use `--check` for a read-only admission probe. A source-reviewed child may be
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
