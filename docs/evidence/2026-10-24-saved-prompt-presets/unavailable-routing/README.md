# Existing saved presets: rejected Runtime references

The installed API on binary `8eac5c07c290d134a9ef6acb1e298584bf9a1366`
listed both actual saved snapshots as unreadable and returned HTTP 404 for
each detail request because the snapshots did not record lane request settings.
The lower stack layer fixes that read. A further real-data restore on its
candidate still failed the Runtime part: `sonnet-5-5-medium` no longer exists.

The follow-up keeps a refused saved assignment's current value or absence,
and keeps an entire refused lane declaration. The real Runtime writer's save
precondition validates changes; unavailable catalog assignments are additionally
excluded using materialized bindings and their canonical capability lookup.
Declared lanes take precedence over same-named bindings. No substitute model
is selected, and ordered lane candidates are never trimmed to pass validation.

`skipped_assignments` and `skipped_lanes` are explicit partial-restore receipts.
The Web panel and TUI decoder/result state preserve them. Runtime unchanged and
committed summaries describe file effects, without asserting that excluded
assignments matched or applied. The Web panel summarizes exclusions and keeps
all reasons in an expandable detail.

## Measurement

Fresh private copies of each actual snapshot restored independently:

| Saved snapshot | Runtime file | Refused assignments | Excluded lanes | Applied instructions | Duration |
|---|---|---:|---:|---:|---:|
| default | committed | 11 | 4 | 28 | 905.473 ms |
| before-keeper-instructions-20261007 | committed | 14 | 4 | 29 | 797.217 ms |

All 63 original operator preset files retained their exact hashes. Each restore
created its rotating `_autosave` only inside its separate copied base.

Focused native Core execution passed 37 cases, Web execution 12 and TUI decoder /
result-state execution 4. The three new Core cases prove valid siblings still
restore, all-refused changes preserve file bytes, and a declared-but-catalog-missing
Runtime cannot replace a healthy assignment even though the general config
writer deliberately permits saving that degraded state. ESLint passed. Dashboard
typecheck retains only the two baseline keeper-stream test diagnostics recorded
in results.json.

Independent source review found and resolved two P2 issues: catalog-unavailable
assignments and misleading unchanged/committed wording. Final source review
reported no P0/P1/P2. This is not formal GitHub approval or a full build.

Browser screenshots use the actual panel with a native-candidate subprocess
adapter over copied data. They establish that the restore response and exclusions
are visible in that fixture. The installed server, native TUI binary and operator
settings were not replaced by these measurements. Runtime registry publication
is separately reported as requiring restart in the isolated process.

- [Machine-readable results and source hashes](results.json)
- [Existing instruction snapshot result](before-instructions-result.png)
- [Default snapshot result](default-result.png)
