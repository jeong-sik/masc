# Independent review of paired-bae

PageUp latency shows an improvement direction (4/5 pairs); general mixed-scroll typing latency improvement is not established. Child process lifecycle CPU is lower in all 25 pairs.

Read-only analysis at 2026-11-09T07:40:30.622243+00:00; fixed cohort 0..4 x before/after x five conditions. All 50 results are present.
This is a derived review of the retained synthetic PTY captures. It is not a product edit, new TUI execution, CI result, or a claim about the operator's physical screen.

Helper SHA-256: `b43594f33f14edbe18d07eb98fac62e8a99c3803f74b0a04fd215ed0e0d30efd`. Before binary: `ebcbe53ff38f8a60ce456bd20d8f05a9542f8deb7fa450400475505078fdb93b`. After binary: `85c7d5bc40b0b99de9bfd9492604f0c3b4176d7cd4f53d85a34d4bd5a1924139`.
800 records x 8 lines, identical history `b1d4d6fa6c3ffc1a1ee129bd2057d57f0460ee5ccc30b138e2dcaca7b584703b`; 32 typed characters per run.

Integrity findings: 0. Missing prefixes: 0. Every run checks exact typed bytes, 33 ACKs, clean exit, stable binary, frozen helper/fixture copies, and capture chunk byte counts.

## Pair-level latency and CPU

Negative latency delta means lower latency after. CPU is the entire child lifecycle.

| Condition | Median run p95 before / after (ms) | Pairs lower after | Median paired p95 delta (ms) | Median paired CPU ratio | Worst key before / after (ms) |
| --- | --- | --- | --- | --- | --- |
| typing | 11.91 / 10.15 | 2/5 | +0.37 | 0.870 | 31.61 / 49.33 |
| pageup | 18.31 / 13.92 | 4/5 | -5.78 | 0.724 | 61.26 / 48.97 |
| pagedown | 24.77 / 19.43 | 2/5 | +1.57 | 0.761 | 72.61 / 75.70 |
| wheelup | 14.13 / 16.40 | 2/5 | +0.36 | 0.826 | 121.34 / 48.39 |
| wheeldown | 13.61 / 16.84 | 2/5 | +6.78 | 0.927 | 47.24 / 65.15 |

PageDown's median run p95 falls when summarized without pair identity, but its median paired delta is positive and only two pairs improve. Typing has the same direction ambiguity. Neither supports a general improvement claim.

| Condition | Pair | Order | Before p95 | After p95 | Delta ms | Before / after CPU s | Before / after load1 | Before / after type-gap median ms | Before / after actual scroll Hz |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| typing | 0 | before -> after | 2.55 | 7.39 | +4.83 | 0.703 / 0.602 | 239.0 / 247.8 | 54.24 / 54.23 | none |
| typing | 1 | after -> before | 17.87 | 16.06 | -1.81 | 0.615 / 0.512 | 262.8 / 259.8 | 54.64 / 53.93 | none |
| typing | 2 | before -> after | 15.17 | 3.51 | -11.65 | 0.621 / 0.543 | 265.1 / 266.3 | 54.83 / 54.44 | none |
| typing | 3 | after -> before | 11.91 | 12.28 | +0.37 | 0.590 / 0.513 | 294.6 / 292.9 | 54.14 / 53.94 | none |
| typing | 4 | before -> after | 8.27 | 10.15 | +1.89 | 0.564 / 0.538 | 271.5 / 272.5 | 54.75 / 54.77 | none |
| pageup | 0 | before -> after | 22.70 | 9.93 | -12.76 | 1.173 / 0.828 | 241.4 / 231.7 | 54.42 / 53.94 | 41.99 / 42.80 |
| pageup | 1 | after -> before | 18.31 | 12.53 | -5.78 | 1.083 / 0.812 | 244.3 / 240.8 | 53.75 / 54.30 | 41.26 / 42.31 |
| pageup | 2 | before -> after | 31.46 | 17.03 | -14.43 | 0.996 / 0.810 | 272.6 / 277.2 | 54.04 / 53.51 | 40.83 / 42.36 |
| pageup | 3 | after -> before | 14.09 | 16.41 | +2.31 | 1.073 / 0.777 | 293.4 / 295.2 | 54.71 / 53.50 | 41.66 / 41.81 |
| pageup | 4 | before -> after | 16.95 | 13.92 | -3.03 | 1.334 / 0.814 | 271.9 / 270.9 | 54.34 / 54.24 | 42.30 / 42.15 |
| pagedown | 0 | before -> after | 24.77 | 37.82 | +13.06 | 1.308 / 0.996 | 234.7 / 231.5 | 54.75 / 54.26 | 41.23 / 41.42 |
| pagedown | 1 | after -> before | 25.01 | 26.58 | +1.57 | 1.389 / 1.056 | 263.6 / 258.0 | 53.67 / 54.08 | 40.91 / 41.77 |
| pagedown | 2 | before -> after | 7.84 | 14.18 | +6.34 | 1.335 / 1.086 | 259.6 / 254.6 | 54.61 / 54.07 | 41.39 / 41.73 |
| pagedown | 3 | after -> before | 20.66 | 8.23 | -12.43 | 1.431 / 1.048 | 302.8 / 294.0 | 54.21 / 53.34 | 40.68 / 41.10 |
| pagedown | 4 | before -> after | 29.08 | 19.43 | -9.65 | 1.359 / 1.069 | 272.2 / 279.2 | 54.50 / 54.27 | 41.92 / 41.96 |
| wheelup | 0 | before -> after | 6.23 | 8.47 | +2.24 | 0.848 / 0.701 | 228.4 / 231.0 | 53.88 / 53.78 | 42.09 / 42.47 |
| wheelup | 1 | after -> before | 53.18 | 28.07 | -25.11 | 0.791 / 0.652 | 261.3 / 263.9 | 54.34 / 54.74 | 41.20 / 40.58 |
| wheelup | 2 | before -> after | 7.33 | 7.69 | +0.36 | 0.766 / 0.681 | 252.8 / 257.8 | 54.39 / 54.21 | 41.82 / 41.41 |
| wheelup | 3 | after -> before | 14.13 | 18.52 | +4.39 | 0.740 / 0.645 | 291.5 / 284.0 | 53.62 / 54.56 | 41.91 / 41.37 |
| wheelup | 4 | before -> after | 17.04 | 16.40 | -0.64 | 0.846 / 0.675 | 278.8 / 278.4 | 54.20 / 54.20 | 41.18 / 41.53 |
| wheeldown | 0 | before -> after | 13.61 | 7.03 | -6.58 | 0.715 / 0.663 | 237.6 / 241.6 | 54.28 / 53.81 | 41.96 / 41.96 |
| wheeldown | 1 | after -> before | 5.44 | 15.94 | +10.51 | 0.677 / 0.604 | 263.8 / 267.4 | 54.06 / 54.49 | 41.44 / 41.11 |
| wheeldown | 2 | before -> after | 6.20 | 18.01 | +11.82 | 0.768 / 0.614 | 261.3 / 263.0 | 54.13 / 53.93 | 41.58 / 41.52 |
| wheeldown | 3 | after -> before | 25.30 | 16.84 | -8.46 | 0.697 / 0.663 | 291.5 / 289.3 | 54.59 / 54.15 | 41.51 / 42.11 |
| wheeldown | 4 | before -> after | 19.55 | 26.33 | +6.78 | 0.721 / 0.668 | 289.7 / 279.3 | 54.99 / 54.55 | 40.33 / 41.32 |

## Environment, cadence and limits

- Run median typing gaps: 53.34..54.99 ms; largest observed gap 74.53 ms.
- Actual scroll rates: 40.33..42.80 Hz. 50Hz was requested, not achieved exactly.
- Host one-minute load endpoints: 228.4..302.8. This is load average, not CPU percent.
- Independent repeat unit is a run/pair, not each of its 32 serially correlated keys.
- The p95 estimator is the helper's lower empirical quantile at floor((n-1)*0.95); for n=32 it is the third-largest sample.
- Requested input cadence is 50ms typing / 20ms scroll; actual rates are retained separately.
- CPU covers TUI startup, history load, positioning, measured typing and teardown, not only the typing phase.
- Wall time also includes helper shutdown and post-run analysis; do not interpret child_cpu/wall as phase CPU utilization.
- High, changing host load and only five paired runs limit extrapolation and individual-change causal attribution.
- PTY prefix emission is not physical terminal paint or proof of exact submitted/stored draft identity; these performance runs did not enable verify-submit.

`observations.json` retains every run result digest, hash/denominator checks, gaps, CPU, host-load observations and all 25 paired comparisons. `analyze.py` reproduces these derived files from the fixed original result paths; it does not launch a TUI or write to the input captures.
