# Latest integrated TUI candidate: rendering and input latency

## Identity and scope

- Comparison [run 36032545600](https://github.com/jeong-sik/masc/actions/runs/36032545600), experiment source `5bb82feefdb010e0526daa9507ab3cc5ba2ea0e5`.
- Result artifact: `10823364522` (`tui-artifact-comparison-36032545600-attempt-1`).
- Baseline: `7af2c5149adc5400969cef3636c858c4b2a8974d`.
- Candidate: `8e2224bde96ba4aeddb79bdbea79ff03482ee1e3`.
- Candidate TUI SHA256: `3ec318b6b5d4134d7748d4c255634757ae4c1276e0a79b41005b6922317db289`.
- Same macOS ARM runner, alternating B/C, C/B, B/C; three observations per action and binary. Full metadata and all binary hashes are in the identity JSON files.
- Ten acknowledged input/scroll transitions and one draft burst per execution: all 60 transitions and all six bursts passed. Downloaded summary was checked equal to the CI logged summary.

Candidate includes ASCII/mixed-Unicode layout work, Codex context/wire workers,
and the latest first-input-immediate/subsequent-input-16ms scheduler. This is
not the earlier `e25a54d8…` candidate; do not carry its sub-2ms observations
forward as proof for this source.

## Input to completed PTY frame

| Action | Baseline median ms | Candidate median ms |
|---|---:|---:|
| arrow down | 32.653000 | 0.632416 |
| arrow up | 52.631375 | 104.889084 |
| wheel down | 64.874625 | 98.520083 |
| wheel up | 77.208708 | 121.728292 |
| page down | 31.287250 | 116.690333 |
| page up | 103.323708 | 124.818583 |
| detail key down | 0.981250 | 1.273333 |
| detail key up | 132.593250 | 22.702875 |
| detail wheel down | 107.832708 | 35.256292 |
| detail wheel up | 35.072833 | 32.073292 |

Candidate observations span **0.512542–136.217875 ms**. The 0.1ms objective
is **not achieved**. Some successive actions are slower than the baseline in
this run. The observations include the Python observer and OS scheduling;
they do not isolate the cause of each wait or prove physical display latency.
The run does not establish a deployed improvement or cover every TUI action.

## Internal frame work

These are per-execution histogram summaries, not action-correlated samples.
They separate time inside frame construction/presentation from the much
longer end-to-end waits above; they must not be substituted for response time.

- `01-baseline.frame-timing.txt`: `build frames=21 mean=0.73ms p50=0.60 p95=1.36 p99=1.87 max=1.87`
- `01-baseline.frame-timing.txt`: `present frames=21 mean=0.09ms p50=0.06 p95=0.27 p99=0.29 max=0.29`
- `02-baseline.frame-timing.txt`: `build frames=20 mean=0.69ms p50=0.58 p95=1.27 p99=1.36 max=1.36`
- `02-baseline.frame-timing.txt`: `present frames=20 mean=0.12ms p50=0.06 p95=0.26 p99=1.00 max=1.00`
- `03-baseline.frame-timing.txt`: `build frames=21 mean=1.24ms p50=0.64 p95=1.46 p99=9.97 max=9.97`
- `03-baseline.frame-timing.txt`: `present frames=21 mean=0.39ms p50=0.06 p95=0.22 p99=6.57 max=6.57`
- `01-candidate.frame-timing.txt`: `build frames=21 mean=0.45ms p50=0.33 p95=0.75 p99=0.94 max=0.94`
- `01-candidate.frame-timing.txt`: `present frames=21 mean=0.08ms p50=0.07 p95=0.21 p99=0.24 max=0.24`
- `02-candidate.frame-timing.txt`: `build frames=20 mean=0.39ms p50=0.35 p95=0.69 p99=0.73 max=0.73`
- `02-candidate.frame-timing.txt`: `present frames=20 mean=0.07ms p50=0.05 p95=0.17 p99=0.31 max=0.31`
- `03-candidate.frame-timing.txt`: `build frames=21 mean=0.47ms p50=0.38 p95=0.72 p99=1.97 max=1.97`
- `03-candidate.frame-timing.txt`: `present frames=21 mean=0.15ms p50=0.06 p95=0.70 p99=1.08 max=1.08`

Candidate build p95 is 0.69–0.75ms across these executions, compared with
1.27–1.46ms baseline. Presentation and frame construction still exceed the
0.1ms target in multiple observations. Lower rendering cost has not removed
the successive-input delay.

## Exact-source integration

[Focused Test 36031136071](https://github.com/jeong-sik/masc/actions/runs/36031136071)
ran on candidate `8e2224bde96ba4aeddb79bdbea79ff03482ee1e3` and passed:
layout 104 cases; scheduler 86; terminal probe 21; Codex transport 107;
Keeper context 9; and the input-frame PTY scenario. This proves those checks,
not latency success. The workflow also ran its separate no-build suite stage.

## Next work

Inspect the input wait/scheduler path and measure sustained input CPU cost.
Keep the same-host comparison, retained identities and acknowledged frame
checks for the next candidate. Investigate waits above the declared 16ms
interval before attributing all of this to render work or the pacing policy.
