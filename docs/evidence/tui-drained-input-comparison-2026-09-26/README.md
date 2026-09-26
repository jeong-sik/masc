# Drained input: same-runner comparison

[Run 36235046411](https://github.com/jeong-sik/masc/actions/runs/36235046411) succeeded on experiment head
`bf3188bfc22018e47303351d021af3202e619c84`. Artifact `10904385253` contains the
complete stdout/stderr, manifests and observations. The JSON observations, identity
receipts, internal frame summaries and aggregate are retained here.

## Source and scope

- Baseline source: `91d1e037044b86cb3d3b548995d5199e85f5931e`, build `36233454333`, artifact `10903815752`.
- Candidate source: `9dc02f5877a9d8c312acc3b1e271b1ede8729e07`, build `36234548433`, artifact `10904140299`.
- Their bin/lib diff is exactly `masc_tui.ml`, `masc_tui_render_schedule.ml` and its interface. Baseline bin/lib equal main base `08cbfc631b610f130bb9f1d9010e309ff211eeef`.
- One macOS ARM runner, alternating B/C, C/B, B/C; ten cycles of ten individually acknowledged transitions per session.
- All 600 transitions and six draft checks passed. Each session also checked startup, explicit draft navigation, shutdown and terminal cleanup.
- Current metadata, both keeper rows acknowledged before timing; preflight normalized-content hashes agree in all six receipts.
- This measures input to the completed expected PTY frame, including Python observer and OS scheduling. It does not measure physical display latency or the deployed TUI.

## Observations

| Action | Baseline median ms | Candidate median ms |
|---|---:|---:|
| arrow down | 18.114876 | 0.438833 |
| arrow up | 18.422959 | 0.404312 |
| wheel down | 18.217666 | 0.399917 |
| wheel up | 18.594375 | 0.395271 |
| page down | 18.222521 | 0.420750 |
| page up | 18.430937 | 0.353834 |
| detail key down | 18.768292 | 0.412750 |
| detail key up | 18.605917 | 0.410062 |
| detail wheel down | 18.676292 | 0.418666 |
| detail wheel up | 18.751521 | 0.418042 |

Across all 300 observations per binary, baseline median was **18.552917ms**
and candidate median **0.408250ms**. Baseline range: 0.570041–61.292167ms;
candidate range: 0.270333–1.642375ms. Every candidate observation remained
above 0.1ms, so the full goal is not achieved.

## Whole-session CPU

| Repetition | Baseline child CPU s | Candidate child CPU s |
|---|---:|---:|
| 1 | 0.308132 | 0.215406 |
| 2 | 0.159543 | 0.121075 |
| 3 | 0.191140 | 0.154906 |

Median CPU was 0.191140s baseline and 0.154906s candidate. This includes
whole reaped launcher/TUI sessions and waited descendants: setup, preflight,
initialization, navigation, draft entry and shutdown. It excludes observer CPU.
It is not per-action CPU and does not establish a fixed-rate overload ceiling.
Drained inputs can now paint more than 63 frames per second; continuous backlog
still uses the frame interval. The measured closed-loop workload used less
whole-session CPU in each pair, but other arrival patterns remain unmeasured.

Earlier failed runs and the 60-transition historical experiment used other
sources or setup. None are pooled into this result. No deployment, browser
result or all-feature coverage is claimed.

## Behavioral CI

[Run 36235047964](https://github.com/jeong-sik/masc/actions/runs/36235047964)
passed at latest source PR head `ab5dcecb3a8e0c4dae4e5faa8c5899ad1590baac`:
90 scheduler cases, 27 terminal-probe cases, 26 decoder cases, the readiness
PTY suite (five scenarios including the large paste), and the input-frame
PTY scenario. `behavior-ci-excerpt.txt` contains the corresponding Test-step
lines; standalone suite output is omitted. This head adds the numbered
changelog and explicit draft navigation fixture to the measured `9dc02f` head;
its bin/lib diff from that measured head is empty.

Independent adversarial review matched raw stdout and receipts, all six
identities, source/helper hashes, action counts and recalculated aggregates.
Source CI, controlled fixture performance and production behavior remain
separate claims. Current-main integration and Keeper merge gates still apply.
