# Independent ff1 active-burst review

Installed eb4 snapshot versus ff1 upgrade, not C-only causal isolation. Five independent pairs per condition; 32 keys within each run are correlated.

Fixed cohort 50/50; integrity/replay discrepancies: 0. All ACKs, frozen binaries/helper/history/fixtures and VT replay inputs were checked; no results were selected out.

## Latency and CPU

| Condition | Pooled p95 before / after ms | Lower-p95 pairs | Median paired delta ms | CPU lower pairs |
| --- | --- | --- | --- | --- |
| typing | 13.58 / 6.20 | 3/5 | -4.81 | 5/5 |
| pageup | 61.49 / 47.04 | 4/5 | -13.47 | 5/5 |
| pagedown | 22.73 / 27.13 | 3/5 | -4.23 | 5/5 |
| wheelup | 39.64 / 20.93 | 3/5 | -23.49 | 5/5 |
| wheeldown | 23.83 / 13.88 | 3/5 | -11.49 | 5/5 |

Whole-child CPU totals: 28.3251 -> 19.4368s, lower in 25/25 pairs. PageDown pooled p95 worsens and must accompany the favorable paired median.

## Active viewport and observer correction

The corrected helper sends 200 PageUp writes before timed input for PageDown and 50 PageUp writes before timed input for WheelDown. These are injected writes, not directly observed page offsets. The actual maximum is 153 scroll writes, so the conservative page movement is 153*37=5661 rows, below the 6363-row minimum available span from 6400 fixture content rows. This replaces the obsolete 151-write bound; the emitted VT Record IDs provide additional observations away from records 0 and 799.
The v1 observer counted unpaired autowrap-enable markers from cleanup as frames and retained stale alternate-screen content in pyte. The v2 observer pairs disable/enable markers and uses scroll write return time. This audit independently replays both versions, preserves the original v1 digest and compares the corrected v2 frames. Cleanup markers do not count as presents.
[pyte's primary documentation](https://github.com/selectel/pyte/blob/master/docs/tutorial.rst) describes Screen as an in-memory terminal text buffer and Stream as its event decoder. This supports VT-model observation, not physical display measurement.

| Condition | Runs | During Record range | Every run changes Record set | Every run has observed present end after last write return |
| --- | --- | --- | --- | --- |
| typing | 10 | 782..782 | False | False |
| pageup | 10 | 519..781 | True | True |
| pagedown | 10 | 453..718 | True | True |
| wheelup | 10 | 758..782 | True | True |
| wheeldown | 10 | 712..736 | True | True |

## Every pair

| Condition | Pair | Order | Before / after p95 | Delta ms | Before / after CPU s | Before / after type gap ms | Before / after scroll Hz | Before / after load1 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| typing | 0 | before -> after | 9.32 / 1.80 | -7.53 | 0.663 / 0.532 | 28.67 / 27.77 | none | 263.9 / 246.9 |
| typing | 1 | after -> before | 16.09 / 6.16 | -9.93 | 0.607 / 0.491 | 29.24 / 28.75 | none | 164.0 / 162.8 |
| typing | 2 | before -> after | 5.12 / 6.80 | +1.69 | 0.595 / 0.472 | 29.62 / 29.26 | none | 202.1 / 207.9 |
| typing | 3 | after -> before | 4.70 / 4.83 | +0.13 | 0.562 / 0.479 | 29.36 / 29.05 | none | 233.8 / 239.4 |
| typing | 4 | before -> after | 8.75 / 3.94 | -4.81 | 0.584 / 0.480 | 29.18 / 29.41 | none | 236.6 / 239.4 |
| pageup | 0 | before -> after | 65.39 / 63.24 | -2.15 | 1.110 / 0.989 | 28.92 / 29.22 | 159.93 / 165.65 | 238.0 / 228.2 |
| pageup | 1 | after -> before | 47.11 / 16.58 | -30.53 | 1.239 / 0.833 | 29.10 / 29.65 | 161.97 / 157.10 | 204.7 / 207.3 |
| pageup | 2 | before -> after | 38.72 / 86.40 | +47.67 | 1.409 / 0.823 | 29.23 / 29.44 | 161.35 / 163.32 | 208.2 / 210.9 |
| pageup | 3 | after -> before | 61.49 / 25.69 | -35.80 | 1.118 / 0.827 | 28.50 / 29.57 | 160.24 / 158.98 | 238.9 / 234.9 |
| pageup | 4 | before -> after | 37.26 / 23.79 | -13.47 | 1.331 / 0.840 | 29.19 / 28.44 | 155.07 / 159.38 | 242.8 / 242.7 |
| pagedown | 0 | before -> after | 22.46 / 4.25 | -18.21 | 1.947 / 1.248 | 28.52 / 29.09 | 163.55 / 166.45 | 222.3 / 212.4 |
| pagedown | 1 | after -> before | 16.75 / 6.53 | -10.22 | 2.049 / 1.201 | 28.79 / 28.92 | 157.46 / 163.55 | 186.7 / 199.1 |
| pagedown | 2 | before -> after | 15.25 / 11.01 | -4.23 | 1.910 / 1.255 | 28.06 / 29.49 | 164.14 / 160.17 | 171.5 / 184.7 |
| pagedown | 3 | after -> before | 9.06 / 22.77 | +13.71 | 1.874 / 1.203 | 28.74 / 28.95 | 158.32 / 158.92 | 240.0 / 241.0 |
| pagedown | 4 | before -> after | 28.52 / 53.04 | +24.53 | 2.113 / 1.187 | 29.59 / 28.55 | 160.65 / 161.23 | 244.5 / 255.9 |
| wheelup | 0 | before -> after | 31.42 / 7.93 | -23.49 | 0.889 / 0.642 | 29.04 / 28.86 | 161.92 / 165.03 | 203.0 / 198.4 |
| wheelup | 1 | after -> before | 32.09 / 3.88 | -28.21 | 0.929 / 0.612 | 28.85 / 29.10 | 155.45 / 162.25 | 171.4 / 173.9 |
| wheelup | 2 | before -> after | 8.87 / 18.30 | +9.43 | 0.800 / 0.597 | 29.08 / 28.87 | 161.86 / 160.20 | 196.3 / 204.7 |
| wheelup | 3 | after -> before | 52.13 / 12.73 | -39.40 | 0.772 / 0.602 | 28.56 / 28.88 | 156.92 / 158.49 | 230.4 / 224.0 |
| wheelup | 4 | before -> after | 29.16 / 29.26 | +0.10 | 0.807 / 0.600 | 29.49 / 29.31 | 160.07 / 155.43 | 259.4 / 261.7 |
| wheeldown | 0 | before -> after | 37.28 / 3.16 | -34.12 | 1.032 / 0.693 | 29.14 / 29.18 | 154.87 / 163.01 | 208.3 / 210.5 |
| wheeldown | 1 | after -> before | 23.34 / 11.85 | -11.49 | 1.003 / 0.707 | 29.46 / 28.97 | 156.33 / 163.08 | 163.5 / 168.4 |
| wheeldown | 2 | before -> after | 19.98 / 3.88 | -16.10 | 1.040 / 0.705 | 28.81 / 28.90 | 152.34 / 158.29 | 196.3 / 198.7 |
| wheeldown | 3 | after -> before | 1.84 / 6.90 | +5.06 | 0.935 / 0.713 | 29.00 / 28.83 | 161.37 / 160.34 | 237.1 / 233.2 |
| wheeldown | 4 | before -> after | 12.05 / 26.92 | +14.87 | 1.007 / 0.705 | 29.49 / 29.28 | 159.00 / 154.02 | 237.6 / 238.2 |

## Claim limits

- VT replay observes the emitted terminal text model, not physical paint. pyte Screen is an in-memory emulator; this does not validate every xterm/Ghostty extension.
- Read-chunk timestamps are upper bounds on emission. A present end observed after a returned scroll write does not prove that write or all later writes were consumed.
- Changing non-boundary Record sets supports actual viewport movement. It does not prove every scroll event changed a viewport or that movement was uniformly smooth.
- CPU totals cover child startup, history reads, positioning, typing and teardown; positioning increased in this cohort, so old-cohort totals are not a causal comparator.
- Earlier C normal-rate PageDown and burst/control results remain retained historical adverse evidence. They concern a different candidate; no normal-rate ff1 cohort was audited here.
- Pooled p95 is descriptive. PageDown pooled p95 worsens despite a negative paired median; no uniform improvement or no-regression claim is supported.
- Exact Unicode request verification, physical display, final installation CAS and live smoke are separate evidence layers.

`observations.json` includes all 50 run digests, raw ACK replay checks, v1/v2 VT comparisons, gaps, load and pair clusters. This is a derived review; source/helper files, raw results and original observations were not edited. `analyze.py` launches no product or CI operation.
