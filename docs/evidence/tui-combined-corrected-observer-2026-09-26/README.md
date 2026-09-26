# Combined TUI changes with the corrected PTY observer

[Comparison run 36241679788](https://github.com/jeong-sik/masc/actions/runs/36241679788)
passed on macOS ARM with the same observer for both binaries. The 27 downloaded
raw files are retained unchanged alongside independently recomputed aggregates.
Each arm performs 300 acknowledged input transitions and three checked drafts.
Execution order is baseline/candidate, candidate/baseline, baseline/candidate.
Each session first measures 60 roster transitions and checks a draft, then
loads 250 synthetic alpha Channels bindings and one beta binding, returns to
Info, and measures 40 detail transitions with those bindings retained.

## Identities and scope

- Harness: `304f5f6f67edcb38e3b2ad5da6759d64f73a4983`.
- Helper SHA-256: `4841c61f45457db49dac8afb8a6714a8a9f109671a33e5e9b96b7cf8d4bd39d8`.
- Scenario SHA-256: `2b12d51f3fb64d0a32924804c601a2f9e489729962da303a6049cada1114af55`.
- Baseline: `53f784617c1867b3ecadb300bc8bd1d0844dd233`, source run
  `36239521218`, artifact `10905313235`.
- Candidate: `f69b7b40a379f3b3ff7fd8060b041d0315b15851`, source run
  `36241260409`, artifact `10906805085`.
- Candidate combines drained-input scheduling (#39270), deferred detail-tab
  construction (#39279), and the Present instrumentation shared with baseline.
  The product diff is four files: `masc_tui.ml`, `masc_tui_render_schedule.ml`,
  its interface, and `masc_tui_render.ml`. This measures the combined effect.
- Both manifests say `release_validated: false`. Artifact metadata, source
  identities, fixture hashes and every binary hash were checked. Neither binary
  was installed into the live runtime.

The measurements cover input to the expected completed PTY frame, including
scheduling and the observer. They do not measure physical terminal display.
The pinned measured helper predates the later main wait-stall diagnostics;
current PR source and these historical measurement sources are distinct.

## Results

All values below are milliseconds. p95 is the nearest-rank percentile.

| Scope | Samples per arm | Baseline median / p95 / max | Candidate median / p95 / max |
|---|---:|---:|---:|
| All inputs | 300 | 18.288626 / 22.165209 / 48.190416 | 0.637042 / 1.493875 / 25.090625 |
| Roster | 180 | 18.248416 / 22.294125 / 29.849834 | 0.666813 / 1.568500 / 25.090625 |
| Info scrolling | 120 | 18.385063 / 22.066292 / 48.190416 | 0.585521 / 1.334000 / 2.160667 |

The candidate maximum is repetition 2, cycle 2, roster `page up`.
No sample was removed. Every candidate observation exceeds the 0.1ms goal;
the candidate minimum is 0.3295ms.

Whole-session child CPU medians are 0.383704s baseline and 0.247911s candidate.
These include startup, navigation, draft entry and shutdown, exclude observer
CPU, and are not per-action CPU measurements.

## Internal frame timing and remaining tails

Each cell lists baseline → candidate. These summaries include all session
frames, including setup; no input-to-internal-frame association is recorded.

| Repetition | Build p95 / max, ms | Present max, ms | Flush max, ms |
|---|---|---|---|
| 1 | 2.75 / 4.74 → 1.03 / 4.87 | 0.66 → 0.80 | 0.653 → 0.733 |
| 2 | 3.07 / 6.34 → 1.18 / 24.46 | 0.61 → 0.91 | 0.599 → 0.897 |
| 3 | 3.96 / 9.09 → 1.02 / 4.07 | 5.06 → 0.54 | 5.045 → 0.533 |

Candidate repetition 2 has a 24.46ms keeper-list Build at frame 21. Its presence
in the same session as the 25.09ms input is not proof that they are the same
event. The candidate's Present maxima remain below 1ms in these three sessions;
this is not a universal tail bound. The earlier 165ms observation is not
explained by this experiment.

Root verification reconciled all receipts with stdout, all summary arrays and
aggregates, all six PASS markers, empty stderr, identical fixture preflight,
and both local artifacts' three binary hashes. Adversarial review independently
recomputed all 600 observations and retained the outlier and scope limitations.
An independent response review confirmed those results and the main integration.
This is controlled synthetic evidence, not deployed performance or goal completion.

`merged-helper-smoke/` is a separate follow-up, using the same candidate binary
and pinned scenario with the merged main helper `cdd6271f169c806f6ba19fd2506daad4a52b33d7daddbb0ef0a7df8f884abe66`.
Its 100 transitions and draft passed. Those timings are not pooled with the
controlled comparison above. This smoke checks the combined wait-stall
diagnostics and readable-wait helper after #39306 merged.
