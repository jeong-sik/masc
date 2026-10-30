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
* `largest-provider-input-aggregate.json` describes the single largest saved
  provider-input observation in the same fixed window. It counts repeated
  pairs of message role and content-addressed artifact reference, excluding
  the first occurrence. The retained message artifact serializes internal
  message fields and is not the provider wire representation. The marker
  syntax and declared lengths were checked, but blob content was not rehashed.
  Different references do not establish different meaning, and artifact bytes
  are not a token or wire-byte saving.
* `exact-lane-aggregate.json` summarizes registrations started during the UTC
  window recorded in that file. The index was read only through its starting
  length at capture time; completions arriving after the window but before the
  index read are included. Registration and completion are joined by their
  internal run ID, with duplicate and malformed rows counted. The input and
  output file references were checked for regular-file status, declared length,
  and SHA-256. The files can change during capture, so this is not an atomic
  snapshot. The 24-hour window spans server restarts; a registration is not
  attributed to the binary running at capture time. The original index is
  `<base>/.masc/exact-lane-runs-v7.jsonl`;
  referenced artifacts remain in the runtime, not in this report.
  `workspace_curator_exact` usage comes from `payload.provider_usage` in the
  checked completion artifact; `librarian_exact` usage comes from the completion
  record. Null usage is missing, not zero. Stored artifact lengths, rendered
  prompts, provider wire bytes, and reported tokens are different measurements.
  Registration counts are not model request counts, and usage records may omit
  failed attempts. Percentiles are nearest-rank over observed values.
* `curator-failure-kinds.json` counts only the closed result labels in verified
  completion artifacts for the same registrations. `curator-overflow-chain.json`
  records selected requests ordered by UUIDv7: a refused root, its committed
  child, two uncertain requests, a committed root covering the remaining
  parent facts, and another refused root. Ordering IDs does not establish
  dispatch or completion order. The child's selected facts and neighbors match
  the first half of its parent. The analysis reread the same initial index byte count and
  rechecked artifact lengths and digests; the index could have changed between
  reads. Identifiers, input text, and artifact paths are not included. This
  sequence alone does not identify the binary used for each request or establish
  the quality of the committed classifications.
* The microVM observation is one review-request chat operation at 17:45–17:47
  KST. Its operation, turn manifest, raw trace, and execution receipt were
  joined in the live workspace without publishing their IDs or contents. The
  same server PID started before that turn and reported the installed commit
  named in the report. A later host inventory is not evidence of the guest's
  mount state at the time of the probe.

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
