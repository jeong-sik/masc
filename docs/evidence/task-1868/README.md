# Approval consumption after a PR base changes

Task: task-1868. This is a real temporary Git history with a fake GitHub API,
not a retarget of a live PR, release result or deployment observation.

The old approval producer at
`b9a0cb5998f191c05a5629763e8f6d68b3818cfa` creates approval 99 against
a parent base. Retargeting the unchanged head to its older ancestor adds the
parent file to the complete diff. A new old-guard process still returns
approval 99 with exit 0. Expected admission is exit 2: this is the red control.

The candidate producer requires the reviewer to supply the base and complete
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

Reproduce from this checkout:

```sh
python3 docs/evidence/task-1868/probe.py .
python3 scripts/review/test_source_review_policy.py
```

The focused suite also exercises head movement, latest FAIL/HOLD, open CR,
author/untrusted approvals, explicit review-snapshot requirements, missing
diff evidence, binary content, executable mode and filename/newline boundaries.
Release verification remains independently required by the existing policy.

Validation: 29 focused cases passed; Ruff and Pyright reported no errors for
the two changed review Python files. Shell syntax is checked with
`bash -n scripts/review/approve-guard.sh`. These are local fixture and source
checks; no live approval, merge, CI dispatch, deployment or restart is claimed.

[근거] Git source object above; commands and raw JSON in this directory;
2026-09-30 UTC; High for the isolated reproduction and local results.
Independent source review and real GitHub approval consumption remain pending.
