# Owned ToolUse input graph and forced-collection cost

This extends the original-message retention finding, not the live-server
performance verdict. The repaired memo can release an original persisted JSON
tree while keeping its separate, equal decoded tree. This is distinct from
the earlier omitted ToolResult.json example.

Production source at 81cf30f3deae4f3efdb22600196b4a962bb471d0 admits ToolUse.input
into history, validates/writes it and decodes a separate tree. Keeper saves can
retain both the memo and plan.decoded in the lineage. In contrast, the ordinary
Agent_turn.make_tool_result path sets json=None; the omitted-field example
alone does not establish a common operational source of scanned JSON trees.
[tool-input-gc-source-path.json](tool-input-gc-source-path.json) retains the exact source excerpts and full-file
hashes. Neither path establishes production size, frequency or release timing.

## Result

Four AB/BA pairs, eight fresh processes, 32 measured rows. Each process runs the
same fixed order: 32768 rows released, 32768 caller-held, 131072 released, 131072
caller-held. Each ToolUse.input row contains a small nested object/list. The
original and decoded inputs are physically distinct and structurally equal.
The source record and original input have weak witnesses. Eight preparatory
full_major calls precede the first observation. A future opaque read keeps the
caller-held positive control alive through timing; released retains no caller
reference. Memo and decoded checkpoint stay held throughout both conditions.

| Input rows | Caller ownership | Baseline CPU seconds | Candidate CPU seconds | Median paired CPU ratio | Candidate minus baseline post-GC live bytes |
| --- | --- | ---: | ---: | ---: | ---: |
|32768|released|1.280171|0.668012|0.514151|-14,147,976|
|32768|held|1.301192|1.319349|1.015311|+32|
|131072|released|4.943285|2.399623|0.484613|-56,615,304|
|131072|held|4.915318|5.014893|1.021113|+32|

CPU seconds are side medians for 24 explicit forced full-major calls, not per
call; ratios are medians of paired ratios. Every released pair is faster for
the candidate. Caller-held CPU is 1.53%/2.11% higher by paired median, with no
original-graph release. This does not supersede the existing warm-save costs:
the 2000-message original-source case previously added 20.8% CPU and 17.2% allocation.
No production workload weighting or total-server CPU benefit is established.

All 32 rows passed before/after input/message liveness expectations. Baseline
keeps originals in both conditions; candidate releases them only when the
caller releases them. Each timed forced-major counter delta is exactly 24.
Cross-side encoded-memo byte count, first-head SHA, content digest and replay
head SHA match. Decoded content_digest and replay-content checks pass after
timing. These oracles cover this fixture, not every serialized object or all
application behavior.

## Measurement boundaries

Sys.time measures process CPU around the 24-call loop, including small loop and
clock overhead. The wall clock is retained but host scheduling varies greatly;
it is not end-to-end latency evidence. Gc.stat before and after timing each
forces another untimed collection. Before-liveness is sampled before the first
stat; after-liveness and live_words follow the second stat. These are stable
outside-timer observations, not exact timer-edge snapshots. Gc.quick_stat is
used only for collection counts. Allocation uses current-domain Gc.counters.

Processes are fresh per implementation/pair, not per row. Earlier rows can
affect later heap and global weak-table history. Both caller-held controls keep
the intended strong roots, but their CPU ratio is not a separate fresh-process
per-row experiment. Live-word gauges belong to the complete owned process after
forced collection; they are neither RSS nor an exclusive retained-size census.
No force-GC change is proposed for the product.

## Native source binding and prior failure

R1 could not compile its harness because its retained Objects CMI and current
prebuilt Agent_core CMI disagreed about Llm_provider__Types. R1 has no native
run or measured verdict; its diagnostic and independent review are preserved.

R2 compiles each complete actual Objects ML/MLI again, then the same fixture,
and links with existing prebuilt dependencies. All 8 steps exit 0 with fatal
warnings 4/8/32/69 retained and empty stderr. Baseline ML/MLI match current
main 81cf30; candidate ML/MLI exactly match published source 0af624, including its
final comments. The 324 recorded prebuilt archive path/hash maps match across
both compilations and remained unchanged at the additional capture check.
These are existing dependency artifacts, not a fresh whole-product source
build. No Dune, CI, product install, server profile/GC/restart, provider request,
original-request replay or merge occurred for this unit.

The complete command vectors, dependency path/hash maps and stdout/stderr remain
in the private capture. Published [native summaries](tool-input-gc-native-summary.json)
and [input hashes](tool-input-gc-inputs.json) bind their recorded scope. The
[preserved R1 failure summary](tool-input-gc-prior-failure.json) identifies the
failed attempt separately. [Raw runs](tool-input-gc-runs.json) and the
[auditor](tool-input-gc-audit-results.py) reproduce the
[audited summaries](tool-input-gc-audited-results.json) into a new output path.
No product suite was repeated. The earlier 23-case leaf result remains separately
bound.
