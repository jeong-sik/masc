# Same-runner TUI artifact comparison

[CI run 36029048099](https://github.com/jeong-sik/masc/actions/runs/36029048099)
at experiment commit `a7c54e3ba9d24b5670def8c23e181b9dbb8eaf0e` verified both
artifact origins and all binary hashes before running the same PTY scenario.
The downloaded artifact summary was compared with the job's logged summary.

| Role | Source commit | TUI SHA256 |
| --- | --- | --- |
| Baseline | `7af2c5149adc5400969cef3636c858c4b2a8974d` | `2b4a34a210ee4d4a6d417297dafe0f1b2e8ae021dc37dd0a2417e2e979bdc12f` |
| Candidate | `e25a54d8b38409ecb0c5244b3e80a9af23f83afe` | `f510bb38826d95ab99f1497d046d303de2e24ea927d0e811fd76e0a1b6f04727` |

The candidate combines the initial ASCII layout, Codex context worker and
immediate input-frame changes. It does **not** contain the later mixed-text or
Codex wire worker changes. It also predates input PR #38821's later pacing
commits `601ef9bc8b` and `eca9323e1d`; this result cannot be used as evidence of
that latest scheduler's latency.

The execution order was baseline/candidate, candidate/baseline,
baseline/candidate on one macOS ARM runner. Each execution checked ten
changed screen states through their completed PTY frames and verified the
entire draft burst. All 60 transitions passed.

| Action | Baseline median ms | Candidate median ms |
| --- | ---: | ---: |
| Arrow down | 0.712 | 0.592 |
| Arrow up | 33.771 | 0.376 |
| Wheel down | 24.068 | 0.519 |
| Wheel up | 40.347 | 0.412 |
| Page down | 25.756 | 0.422 |
| Page up | 65.301 | 0.347 |
| Detail key down | 1.575 | 1.012 |
| Detail key up | 22.843 | 0.775 |
| Detail wheel down | 50.833 | 1.425 |
| Detail wheel up | 72.332 | 1.440 |

Candidate observations ranged from 0.278833 to 1.968958ms. The 0.1ms objective
was not met. These are three samples per action and binary, with Python/PTY
and OS scheduling included. They establish this fixture comparison only;
physical display latency, live workspace behavior, sustained repeated-input
CPU use, the latest paced scheduler and server performance remain unproven.

## Later integrated candidate

The [candidate2 comparison](../tui-artifact-comparison-candidate2-2026-09-25/README.md) measures the latest paced scheduler and retains internal frame histograms. Its successive-input results remain above target and must not be replaced with the earlier immediate-input measurements in this directory.
