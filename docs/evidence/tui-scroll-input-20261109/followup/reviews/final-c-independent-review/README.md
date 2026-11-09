# Independent final-c measurement review

Installed eb4e550c snapshot versus candidate b7d717df upgrade; candidate includes other intervening main TUI changes, so this does not isolate C-only causality.

## Verdict and claim boundary

In this synthetic upgrade comparison, median paired p95 was lower for all four recorded burst scroll-key streams (3/5 or 4/5 pairs). The downward burst streams include tail-clamped no-ops and do not prove continuous active scrolling. Whole-child CPU was lower in all 50 pairs.

The broad claims below are not supported: Uniform latency improvement, no performance regressions, continuously active downward burst scrolling, C-only causality, physical display improvement, or extrapolation to every real conversation.

Both observed regressions must accompany any summary. This review does not classify a noisy tail regression as a proven C-only source defect or replace source/shipping approval.

Fixed cohort: 100/100 results, 0 integrity issues, 0 unobserved prefixes; CPU lower in 50/50 pairs.
Every run was checked for frozen binary/helper/fixture/history hashes, 32 exact typed bytes, ordered 33 prefixes, complete writes, causal ACK clocks, retained capture replay, byte counts and original aggregate result digests.

## Conditions and paired outcomes

A negative paired delta means lower p95 after. Pooled p95 is descriptive, not an independent-sample significance estimate.

| Rate | Condition | Pooled p95 before / after ms | Lower p95 pairs | Median paired delta ms | CPU lower pairs | Median CPU ratio |
| --- | --- | --- | --- | --- | --- | --- |
| normal | typing | 25.57 / 8.16 | 5/5 | -10.20 | 5/5 | 0.823 |
| normal | pageup | 110.04 / 96.94 | 3/5 | -15.71 | 5/5 | 0.679 |
| normal | pagedown | 37.84 / 73.27 | 3/5 | -6.30 | 5/5 | 0.690 |
| normal | wheelup | 47.66 / 28.80 | 3/5 | -3.94 | 5/5 | 0.760 |
| normal | wheeldown | 20.37 / 16.25 | 3/5 | -2.48 | 5/5 | 0.784 |
| burst | typing | 5.96 / 13.33 | 2/5 | +4.59 | 5/5 | 0.807 |
| burst | pageup | 215.97 / 138.10 | 3/5 | -31.24 | 5/5 | 0.806 |
| burst | pagedown | 30.10 / 8.81 | 4/5 | -5.51 | 5/5 | 0.703 |
| burst | wheelup | 79.67 / 65.67 | 4/5 | -2.32 | 5/5 | 0.661 |
| burst | wheeldown | 54.43 / 11.34 | 4/5 | -36.87 | 5/5 | 0.863 |

Normal PageDown: pooled p95 37.84 -> 73.27ms; pair 0 p95 69.42 -> 117.76ms and pair 3 6.23 -> 28.23ms account for adverse clusters. Do not hide them behind its -6.30ms median paired delta.
Burst typing without scroll: pooled p95 5.96 -> 13.33ms; pairs 2/3/4 worsen, so this is not merely a favorable paired direction masked by pooling.

## P2: Downward burst streams reach the tail

The frozen helper positions PageDown 100 pages back, but the burst sends 141..151 PageDown requests. For every before/after run, 9..11 of 32 characters are sent after request 100. With the same reserved page budget, those later requests are tail-clamped no-ops.
WheelDown begins 10 pages back. Both source heads have 45 terminal rows, fixed chrome 8, page_rows<=37 and 3 rows per wheel notch, so the initial offset is at most 370 rows and notch 124 reaches the live edge. All ten burst WheelDown runs send 145..152 notches; 4..6 characters occur after notch 124.
These are workload-validity findings, separate from the zero capture/hash integrity issues. Keep all original results and do not relabel their downward burst p95 as continuous active-scroll improvement. `burst-active-scroll-boundary.json` retains per-run evidence and source coordinates. A corrected workload needs enough starting distance and an audit of actual direction writes; any run hitting a boundary remains a recorded limited observation.

## Every paired cluster

CPU is the whole process lifecycle; gap is the median actual typing-write interval. Load is the one-minute host load before each run.

| Rate | Condition | Pair | Order | Before / after p95 ms | Delta ms | Before / after max ms | Before / after CPU s | Before / after type gap ms | Before / after scroll Hz | Before / after load1 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| normal | typing | 0 | before -> after | 28.60 / 7.13 | -21.47 | 51.64 / 12.39 | 0.715 / 0.577 | 54.88 / 54.92 | none | 221.1 / 225.4 |
| normal | typing | 1 | after -> before | 7.00 / 3.91 | -3.09 | 16.13 / 11.76 | 0.601 / 0.495 | 54.13 / 54.58 | none | 192.9 / 200.5 |
| normal | typing | 2 | before -> after | 22.41 / 7.66 | -14.75 | 44.00 / 10.43 | 0.620 / 0.524 | 53.79 / 54.24 | none | 134.6 / 123.7 |
| normal | typing | 3 | after -> before | 11.26 / 5.79 | -5.47 | 14.88 / 16.82 | 0.662 / 0.512 | 54.28 / 53.91 | none | 95.9 / 92.1 |
| normal | typing | 4 | before -> after | 14.27 / 4.07 | -10.20 | 36.25 / 14.37 | 0.602 / 0.519 | 54.00 / 54.19 | none | 80.7 / 81.1 |
| normal | pageup | 0 | before -> after | 120.44 / 184.66 | +64.22 | 139.63 / 256.30 | 0.878 / 0.675 | 54.56 / 53.88 | 41.76 / 41.39 | 233.4 / 242.5 |
| normal | pageup | 1 | after -> before | 58.04 / 39.62 | -18.41 | 84.92 / 101.99 | 1.169 / 0.794 | 53.46 / 54.45 | 42.31 / 41.72 | 257.6 / 258.7 |
| normal | pageup | 2 | before -> after | 24.40 / 8.69 | -15.71 | 44.83 / 22.95 | 1.245 / 0.766 | 53.93 / 54.33 | 40.95 / 40.83 | 118.9 / 113.7 |
| normal | pageup | 3 | after -> before | 184.63 / 16.22 | -168.40 | 244.90 / 48.56 | 1.102 / 0.756 | 54.25 / 54.82 | 41.21 / 41.15 | 96.3 / 101.0 |
| normal | pageup | 4 | before -> after | 21.53 / 75.49 | +53.96 | 28.39 / 79.07 | 1.126 / 0.708 | 54.59 / 54.35 | 40.81 / 40.00 | 78.3 / 76.7 |
| normal | pagedown | 0 | before -> after | 69.42 / 117.76 | +48.35 | 92.51 / 153.32 | 1.235 / 0.829 | 54.62 / 54.29 | 41.58 / 40.14 | 248.7 / 250.8 |
| normal | pagedown | 1 | after -> before | 11.18 / 4.88 | -6.30 | 34.11 / 49.48 | 1.290 / 0.891 | 53.93 / 53.27 | 42.06 / 42.46 | 244.4 / 256.2 |
| normal | pagedown | 2 | before -> after | 26.01 / 15.39 | -10.63 | 38.13 / 31.54 | 1.292 / 0.933 | 53.94 / 53.54 | 41.81 / 42.55 | 179.7 / 171.5 |
| normal | pagedown | 3 | after -> before | 6.23 / 28.23 | +22.00 | 9.05 / 73.27 | 1.210 / 0.909 | 54.36 / 54.56 | 41.87 / 40.17 | 90.8 / 91.4 |
| normal | pagedown | 4 | before -> after | 27.49 / 7.44 | -20.05 | 32.91 / 23.95 | 1.373 / 0.857 | 55.00 / 54.27 | 40.63 / 41.26 | 75.8 / 72.5 |
| normal | wheelup | 0 | before -> after | 58.59 / 44.33 | -14.27 | 75.30 / 49.92 | 0.808 / 0.641 | 54.24 / 53.32 | 40.37 / 41.27 | 249.7 / 258.3 |
| normal | wheelup | 1 | after -> before | 30.91 / 26.96 | -3.94 | 57.39 / 34.67 | 0.785 / 0.596 | 54.56 / 53.69 | 41.98 / 41.87 | 227.9 / 234.4 |
| normal | wheelup | 2 | before -> after | 7.88 / 3.26 | -4.62 | 16.34 / 17.40 | 0.798 / 0.592 | 54.20 / 54.32 | 42.05 / 41.90 | 164.2 / 151.6 |
| normal | wheelup | 3 | after -> before | 7.24 / 16.31 | +9.06 | 19.84 / 25.63 | 0.963 / 0.634 | 54.03 / 53.08 | 41.79 / 42.48 | 98.9 / 109.7 |
| normal | wheelup | 4 | before -> after | 5.80 / 15.79 | +9.99 | 19.07 / 37.76 | 0.734 / 0.615 | 54.50 / 53.73 | 41.61 / 41.48 | 71.3 / 68.6 |
| normal | wheeldown | 0 | before -> after | 14.71 / 9.67 | -5.03 | 37.73 / 16.25 | 0.759 / 0.595 | 53.76 / 53.28 | 42.09 / 41.72 | 259.7 / 255.6 |
| normal | wheeldown | 1 | after -> before | 12.84 / 15.66 | +2.82 | 33.55 / 63.91 | 0.750 / 0.563 | 54.29 / 54.11 | 41.94 / 42.11 | 208.2 / 216.5 |
| normal | wheeldown | 2 | before -> after | 12.70 / 10.23 | -2.48 | 20.72 / 20.61 | 0.673 / 0.552 | 54.56 / 54.56 | 41.28 / 41.24 | 142.8 / 139.2 |
| normal | wheeldown | 3 | after -> before | 26.63 / 5.70 | -20.93 | 44.54 / 15.89 | 0.733 / 0.584 | 54.17 / 53.44 | 40.97 / 40.68 | 88.9 / 93.8 |
| normal | wheeldown | 4 | before -> after | 9.41 / 17.22 | +7.81 | 37.54 / 20.79 | 0.720 / 0.544 | 54.10 / 54.75 | 40.87 / 40.72 | 87.3 / 84.1 |
| burst | typing | 0 | before -> after | 7.83 / 1.07 | -6.76 | 14.77 / 20.80 | 0.564 / 0.494 | 29.05 / 28.63 | none | 66.6 / 63.3 |
| burst | typing | 1 | after -> before | 4.46 / 3.68 | -0.79 | 33.47 / 8.86 | 0.557 / 0.467 | 28.68 / 29.13 | none | 147.0 / 139.6 |
| burst | typing | 2 | before -> after | 3.39 / 7.98 | +4.59 | 5.67 / 10.21 | 0.596 / 0.481 | 28.76 / 27.86 | none | 190.6 / 196.9 |
| burst | typing | 3 | after -> before | 6.63 / 15.46 | +8.83 | 8.37 / 40.62 | 0.732 / 0.521 | 28.92 / 29.13 | none | 237.3 / 234.2 |
| burst | typing | 4 | before -> after | 2.59 / 13.99 | +11.40 | 24.51 / 25.29 | 0.634 / 0.468 | 28.95 / 28.71 | none | 275.3 / 276.1 |
| burst | pageup | 0 | before -> after | 16.73 / 26.85 | +10.11 | 22.80 / 57.89 | 1.323 / 0.747 | 29.13 / 29.08 | 161.45 / 157.43 | 65.0 / 62.0 |
| burst | pageup | 1 | after -> before | 107.21 / 28.29 | -78.92 | 133.10 / 31.54 | 1.030 / 0.835 | 29.26 / 28.36 | 149.14 / 160.51 | 56.1 / 54.4 |
| burst | pageup | 2 | before -> after | 259.86 / 191.64 | -68.22 | 310.21 / 198.20 | 0.866 / 0.698 | 28.98 / 28.68 | 157.32 / 158.49 | 203.9 / 213.7 |
| burst | pageup | 3 | after -> before | 152.47 / 164.66 | +12.19 | 161.02 / 226.06 | 1.053 / 0.647 | 28.34 / 29.25 | 167.59 / 152.12 | 241.9 / 238.8 |
| burst | pageup | 4 | before -> after | 125.30 / 94.06 | -31.24 | 180.89 / 108.70 | 0.859 / 0.757 | 29.26 / 28.78 | 164.33 / 164.98 | 281.8 / 290.7 |
| burst | pagedown | 0 | before -> after | 4.44 / 1.10 | -3.34 | 16.37 / 1.50 | 1.106 / 0.717 | 28.54 / 27.83 | 159.01 / 167.54 | 61.6 / 58.6 |
| burst | pagedown | 1 | after -> before | 52.53 / 5.64 | -46.89 | 107.12 / 6.82 | 1.075 / 0.836 | 28.75 / 29.05 | 152.16 / 164.34 | 59.3 / 59.9 |
| burst | pagedown | 2 | before -> after | 9.82 / 4.30 | -5.51 | 15.49 / 21.94 | 1.241 / 0.886 | 28.54 / 28.54 | 162.19 / 161.68 | 155.9 / 163.0 |
| burst | pagedown | 3 | after -> before | 43.57 / 8.81 | -34.76 | 74.76 / 31.36 | 1.268 / 0.891 | 28.86 / 28.37 | 158.91 / 161.36 | 245.8 / 242.4 |
| burst | pagedown | 4 | before -> after | 8.60 / 63.80 | +55.20 | 15.08 / 122.56 | 1.617 / 0.912 | 28.18 / 28.19 | 167.59 / 168.26 | 294.1 / 298.4 |
| burst | wheelup | 0 | before -> after | 3.00 / 1.42 | -1.58 | 3.56 / 22.87 | 0.711 / 0.469 | 28.66 / 28.54 | 163.55 / 165.13 | 52.8 / 50.2 |
| burst | wheelup | 1 | after -> before | 152.84 / 58.79 | -94.05 | 213.09 / 86.48 | 0.952 / 0.558 | 28.51 / 28.09 | 161.00 / 157.17 | 89.4 / 81.3 |
| burst | wheelup | 2 | before -> after | 79.67 / 22.41 | -57.27 | 115.33 / 119.59 | 0.788 / 0.612 | 29.21 / 28.74 | 159.42 / 161.83 | 171.9 / 175.1 |
| burst | wheelup | 3 | after -> before | 32.48 / 30.17 | -2.32 | 60.20 / 56.35 | 1.010 / 0.623 | 28.89 / 29.22 | 164.00 / 164.70 | 221.1 / 216.1 |
| burst | wheelup | 4 | before -> after | 45.88 / 117.34 | +71.47 | 78.24 / 176.44 | 0.876 / 0.618 | 28.87 / 27.88 | 165.13 / 161.52 | 303.4 / 300.5 |
| burst | wheeldown | 0 | before -> after | 5.89 / 6.64 | +0.75 | 12.34 / 10.20 | 0.670 / 0.589 | 28.88 / 28.69 | 159.03 / 159.88 | 50.2 / 48.5 |
| burst | wheeldown | 1 | after -> before | 64.80 / 12.85 | -51.95 | 92.47 / 22.63 | 0.734 / 0.640 | 28.68 / 28.59 | 167.31 / 158.31 | 132.3 / 105.2 |
| burst | wheeldown | 2 | before -> after | 31.94 / 4.78 | -27.15 | 51.37 / 20.86 | 0.805 / 0.588 | 29.37 / 29.27 | 160.91 / 161.34 | 181.0 / 193.6 |
| burst | wheeldown | 3 | after -> before | 85.37 / 10.04 | -75.33 | 124.72 / 35.66 | 0.738 / 0.621 | 28.61 / 29.42 | 161.28 / 160.28 | 232.5 / 225.1 |
| burst | wheeldown | 4 | before -> after | 47.89 / 11.02 | -36.87 | 62.67 / 19.28 | 0.774 / 0.668 | 28.65 / 28.93 | 158.41 / 160.94 | 254.8 / 273.5 |

## Cadence, environment and limits

- normal: actual run-median typing gaps 53.08..55.00ms; actual scroll 40.00..42.55Hz; host load1 endpoints 66.6..259.7 (load average, not CPU percent).
- burst: actual run-median typing gaps 27.83..29.42ms; actual scroll 149.14..168.26Hz; host load1 endpoints 48.5..303.4 (load average, not CPU percent).
- Five independent run pairs per condition/rate; the 32 serially correlated keys within each run are not independent repetitions.
- Pooled p95 uses 160 keys per label/condition only as a descriptive statistic; normal and burst cohorts are not pooled together.
- Whole-child CPU includes startup, history loading, positioning, measured typing and teardown; it is not phase-only CPU.
- Actual input gaps/rates and high changing load are retained for every pair. Requested rates must not be reported as achieved rates.
- ACK capture replay uses the reviewed frozen streaming decoder and retained raw read timestamps; this is not an independent physical-terminal renderer.
- Performance runs did not enable verify-submit. Exact Unicode submitted-message identity belongs to the separate owned-peer verification, not these 100 runs.
- Candidate binary/source receipt linkage is checked here; source correctness, CI completeness, installation rollout and shipping approval are separate evidence layers.

## Evidence

`observations.json` preserves every result/capture digest, all run-level checks, raw-clock-derived summaries, per-pair gaps/load/CPU, and comparisons with the original aggregate outputs. Raw captures remain in sibling `paired-final-normal` and `paired-final-burst` directories. This is a derived observational review, not a new product run or CI invocation. `analyze.py` only reads those fixed inputs and writes this independent review directory.

Before binary SHA-256 `ebcbe53ff38f8a60ce456bd20d8f05a9542f8deb7fa450400475505078fdb93b`; after `9941db5ae67c7da195ae220a8f75ec4988c0a8b09ebb28ca8e7c4990e952f6df`; frozen helper `b43594f33f14edbe18d07eb98fac62e8a99c3803f74b0a04fd215ed0e0d30efd`.
