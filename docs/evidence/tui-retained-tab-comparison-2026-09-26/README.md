# Retained Channels data while scrolling Info

[Run 36238470111](https://github.com/jeong-sik/masc/actions/runs/36238470111)
completed on one macOS ARM runner at experiment head
`3682dd946603dee3fb80ad1eeadcf06d2a018342`. Artifact `10905157304` (36,524 bytes)
contains the 27 raw files copied here without byte changes.
`verified-aggregates.json` was independently recomputed from the six receipts.

## Identity and isolation

| | Baseline | Candidate |
|---|---|---|
| Source | `d40a5b18e6c5db66340c34f8946c08724a4cb98a` | `9c244cd88c147811a8534ee7df4c0ffb160f5000` |
| Release build | 36237833472 | 36237885748 |
| Runtime artifact | 10905415521 | 10905405434 |
| TUI SHA-256 | `4cf5b875c008d7cf178177194b138534d8d993ff07a969b00a86b5d1359d3d49` | `5b301789c8b0d8f04304fa0500264c05e6d9da8aa12de7fe1f444c156ecdb685` |

Both builds share main `5bb84d077c4adeb3e3c06df5511019c6b1184f40` and the drained
input scheduler from #39270. Their bin/lib diff is only the four deferred tab
builders from #39279 in `bin/masc_tui_render.ml`. The other changed file is its
changelog fragment. These are integration/probe artifacts with
`release_validated: false`, not installed or published release evidence.

The comparator verified artifact repository/run/commit/architecture, expiry,
manifest binary set and all binary hashes before execution. All six raw stdout
JSON records match the retained receipts; stderr files are empty. Scenario and
helper hashes match the experiment checkout, preflight matches across all runs,
and every summary action array/minimum/median/maximum was recomputed exactly.

## Workload and results

Order is baseline/candidate, candidate/baseline, baseline/candidate. Each session
has ten cycles: six roster transitions per cycle, a checked draft, then a
Channels setup and four Info scroll transitions per cycle. Total: 600
acknowledged input transitions and six draft checks. The 240 detail transitions
are 120 per binary. The 360 roster transitions happen before Channels setup.

The fixture holds 250 alpha bindings, one beta binding and 250 channel names.
It serves separate server/channel/person scopes with cursor pagination. Setup
requires a completed screen with `250 here / 251 total` and a resolved name,
then a completed return to Info. Fixture hash:
`a57996f8ba3a01b5357180200dbd61d7ec7433dbd799b07ec2609efe4e2b73a8`.
The density is synthetic and does not describe the live runtime.

| Measure | Baseline | Candidate |
|---|---:|---:|
| Info scroll median, ms | 1.1155835 | 0.4615625 |
| Info scroll p95, ms (nearest rank) | 2.202167 | 1.374 |
| Info scroll range, ms | 0.988541–3.354459 | 0.331875–2.957 |
| Roster median, ms | 0.533417 | 0.4833955 |
| Roster maximum, ms | 2.029583 | 22.606334 |
| All 300 inputs median, ms | 0.8500625 | 0.471479 |
| Whole-session child CPU median, seconds | 0.225243 | 0.195714 |

Info medians for repetitions 1/2/3: baseline 1.1120835 / 1.0536465 / 1.182896ms;
candidate 0.4537285 / 0.5223955 / 0.453313ms. Each repetition has lower candidate
Info median. This establishes a reduction in this controlled retained-data
workload; it does not establish a latency bound for all product actions.

## Limits and retained outliers

- Every candidate observation exceeds the 0.1ms goal.
- Candidate repetition 1, cycle 1, roster `page up` takes 22.606334ms, before
  Channels loads. Its cause is not established; it remains in all aggregates.
- Whole-session internal `present[keeper-detail]` maxima are 24.91 / 121.97 /
  165.06ms for the candidate. These include untimed setup and have no per-input
  correlation. They preclude claiming every frame is bounded by the timed
  scroll maximum. No samples or internal timing outliers were removed.
- Input-to-frame timing includes the PTY and Python observer, not a physical
  display. Inputs form a closed loop, not fixed-rate overload.
- Child CPU includes reaped launcher/TUI/waited descendants, startup, fixture
  loading, Channels rendering, navigation, draft and shutdown; observer CPU is
  excluded. It is not Info-only CPU. Frame histograms also include setup frames.
- This experiment is separate from the older 600-transition scheduler result
  in `../tui-drained-input-comparison-2026-09-26/`; neither is a deployed-runtime
  measurement. No server was restarted or deployed for this comparison.
