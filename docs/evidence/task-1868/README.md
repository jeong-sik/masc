# Approval consumption after a PR base changes

Task: task-1868. This is a real temporary Git history with a fake GitHub API,
not a retarget of a live PR, release result or deployment observation.

The old approval producer at
`1f1cd345b3f81459004371b53ca647433df31dce` (the parent of the original
diff-binding change, reachable from this PR's history) creates approval 99 against
a parent base. Retargeting the unchanged head to its older ancestor adds the
parent file to the complete diff. A new old-guard process still returns
approval 99 with exit 0. Expected admission is exit 2: this is the red control.

The recorded candidate producer requires the reviewer to supply the base and complete
change hash captured at review time. A fresh consumer yields:

| Case | Expected and observed exit | Approval |
|---|---:|---|
| Unchanged head and complete diff | 0 | original 99 |
| Retarget adds the parent's change | 2 | refused |
| Parent landing removes one reviewed feature | 2 | refused |
| Base SHA and ref move, complete diff unchanged | 0 | original 99 |

`receipt.json` preserves exact temporary commit IDs, before/after hashes,
the actual produced review bodies and consumer stdout/stderr. The original
candidate approval body remains byte-identical. Actions requests: none.

Reproduce the historical receipt with both source commits available locally:
`93cc6dc01fa557022687d47305bb95c7e9016229` contains the probe and fixture, and
`1f1cd345b3f81459004371b53ca647433df31dce` contains the old guard. Fetch missing
history first in a shallow or partial clone. These are historical checks, not
checks of the current source-review policy.

```sh
evidence_checkout="$(mktemp -d)"
git worktree add --detach "$evidence_checkout" 93cc6dc01fa557022687d47305bb95c7e9016229
python3 "$evidence_checkout/docs/evidence/task-1868/probe.py" "$evidence_checkout"
python3 "$evidence_checkout/scripts/review/test_source_review_policy.py"
git worktree remove "$evidence_checkout"
```

The pinned suite also exercises head movement, latest FAIL/HOLD, open CR,
author/untrusted approvals, explicit review-snapshot requirements, missing
diff evidence, binary content, executable mode and filename/newline boundaries.
Release verification remains independently required by the existing policy.

The receipt was regenerated on 2026-10-01 against the reachable baseline above.
The old guard still accepts the expanded diff; the recorded candidate guard refuses both
changed-diff cases and preserves the original approval for identical diffs.
All 43 focused policy tests passed, including root/nested tree-filtered clones
with an unavailable caller remote. Python AST and diff checks passed.
These are local Git and fake-GitHub fixture checks; no live approval, merge,
CI dispatch, deployment or restart is claimed.

[근거] Git source object above; commands and raw JSON in this directory;
2026-10-01 UTC; High for the isolated reproduction and local results.
Independent source review and real GitHub approval consumption remain pending.
