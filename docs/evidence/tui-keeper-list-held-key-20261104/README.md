# Keepers held-key frames, before and after the roster join fix

2026-11-04. Analysis: [research note](../../research/tui-frame-cost-and-terminal-output-prior-art-20261104.md).

## before/

Installed `masc-tui` built 2026-11-04 10:12 from main, against the live
workspace (43 Keepers, 375 active tasks). Ghostty profile, 55 x 200 PTY.

- `harness-result.json`: `scripts/tui-frame-latency.py --scenario keepers
  --keys 40 --gap 0.03`, trimmed of per-write timestamps. Host load average
  253 → 250 (1-minute) across the run.
- `frame-timing-summary.txt`: the TUI's own Build and Present percentiles per
  surface and per stage.
- `frames.jsonl`: one record per Build and Present, as the TUI wrote them.
- `unattributed-per-frame.txt`: Build time outside every timed stage, per frame.
- `sample-top-of-stack-all-threads.txt`: macOS `sample` for 8 s during a
  150-key run (all threads, top of stack). The UI thread was off its poll in
  1,569 of 2,232 samples. At this load a runnable thread waiting for a core is
  sampled too, so these are shares of wall time, not CPU time.

What these do not show: physical key-to-glass latency, other surfaces, or
behaviour on an idle host.

## after/

Same harness and live workspace. The new binary is
`_build/default/bin/masc_tui.exe` from this branch (base `556b7739880`); the
old one is the installed binary above. Host load average 150 to 250 for all of
it, so every wall-clock number here moves with the host.

- `component-bench.txt`: `bench_keeper_list_rows.ml.txt` (not part of the
  product build) runs main's `keeper_list_rows` body, copied verbatim, with its
  sort reduced to the Grouped + Recent case the operator uses (it calls
  `group_of_row`, whose result this change keeps), against the new one on the
  same state: 43 Keepers, 375 active tasks with the live status mix
  (todo 337, in_progress 31, awaiting_verification 6, claimed 1). Both return
  the same rows in the same order. Allocation is deterministic: 96,872 →
  58,752 minor bytes per call. The median time per call fell 1,103 → 270 us in
  one run and 462 → 143 us in the stored one. Single rounds ranged from 1.3 to
  16 times faster because the host load moved under them.
- `alternating-native-runs.txt`: old, new, old, new, old, new; 40 Down then 40
  Up at 30 ms. Frames drawn for the same 80 keys: 82/108/73 old,
  151/127/109 new. Key write to next PTY output, p50 per direction: old
  36/45, 43/21, 54/23 ms; new 24/15, 20/29, 29/14 ms. Build p50 for the list
  moved little (2.27/2.46/3.06 → 1.89/2.55/2.26 ms): most of the removed work
  ran outside Build, in the loop between frames.
- `ui-thread-samples.txt`: 8 s `sample` of each binary during a 150-key run,
  UI thread only. Old: off its poll in 488 of 518 samples, and the roster
  join (`List.exists`, the model closure, `caml_string_equal`, `List.find_opt`,
  `primary_activity_of_row`) took about 63% of those. New: 729 of 1,101, with
  none of those frames near the top. The next largest Keepers cost is
  `sanitize_terminal_text` under `keeper_runtime_cells`, which measures every
  row's runtime text each frame.

### Small roster, many tasks

The [rejected index bundle](../extreme-performance-20261030/keeper-projection-rejected/README.md)
of 2026-10-30 turned down eager indexing because it slowed small query sets.
The same bench with `K=2` (two Keepers, 375 tasks) shows that cost here too.
In the stored run (last block of `component-bench.txt`, after the review
fixes) the median went 35 → 74 us and allocation 2,344 → 7,256 bytes per
call; an unstored run just before it gave 34 → 57 us. With the live 43
Keepers the stored run gives 680 → 250 us and 96,872 → 59,136 bytes. The live
roster is the case the operator reported; 40 us is a quarter of a percent of a
16 ms frame.
