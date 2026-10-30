# Weekly core audit: selected evidence

The companion [report](../../reports/2026-10-30-weekly-core-audit.md) distinguishes
source inspection, the running binary, and tests. These are sanitized aggregates:
no prompt, message, model response, keeper name, credential, or individual memory
claim is retained here.

* `diff-windows.json` compares adjacent rolling 24-hour first-parent snapshots,
  ending at 2026-10-30 17:08:10 Asia/Seoul. Each endpoint is a full commit id.
  File and line counts use `git diff --no-renames --numstat <older> <newer>`
  and include all paths, including documentation and tests. A moved file is
  counted as a deletion and an addition; this can inflate both figures.
* `runtime-aggregate.json` was captured at the timestamp inside that file from
  the running workspace, whose binary commit was
  `bac52cac7934ce3f75c315d474cc23f2561268c9`. Provider-input records are restricted
  to the stated storage interval after that server started. Each turn retains
  its last observed provider input and earlier attempts can be absent. Storage
  time does not establish dispatch time. `body_bytes` records serialization
  before dispatch, not proof of transmission or acceptance. The
  tool-schema byte sums are stored artifact lengths, not a wire-byte breakdown.
* Last-prompt block lengths come from the latest retained snapshot for each
  keeper at capture time. These files are a separate population, can predate the
  restart, and their blocks are not necessarily independent or additive.
* Memory recall summarizes the retained current and one rotated
  `memory-recall-evaluations.jsonl` file per keeper. It is not a fleet-wide or
  complete-history count. Usage is the sum reported on response records; it is
  not a price or a cache-miss measurement. Counts of identical candidate JSON
  and complete request JSON are scoped to the same keeper; neither establishes
  that a model response can safely be reused. There may be other missing or
  rotated-away records. Capture reports malformed or unreadable input counts;
  unknown block, status, or kind labels are counted without exposing their values.

Regenerate a current aggregate without emitting record contents, after selecting
the actual effective workspace base and a UTC provider-input window:

```sh
python3 docs/evidence/2026-10-30-weekly-core-audit/summarize_runtime.py \
  --base-path "$WORKSPACE_BASE" \
  --from-time 2026-10-30T07:46:18Z \
  --until-time 2026-10-30T08:10:00Z
```

The provider window stays fixed in this command, but last-prompt and retained
recall files change as the server operates and rotates files. A later aggregate
is a new observation, not a byte-identical reproduction of this capture. The
script is read-only and outputs aggregated numbers, times, and closed block names.
It rejects a missing Keeper runtime directory; an empty result does not prove
that a rotated or missing file never existed.
