# TUI smoothness measurements — 2026-11-04

PR: https://github.com/jeong-sik/masc/pull/48149

`summary.json` is a selected, derived record. It does not replace the original PTY results or allocation profiles in `artifacts/tui-sse-smooth-20261104/`.

## Source and proof

- Baseline: local `masc_tui.exe`, SHA-256 `30097752da2bea774d0ac48ecf2663c7ca9d74c601016cc37f01508b036999ae`. Its exact Git source was not established by the capture.
- Production change: `d1d1efe159fdff85ad23010359a00c156ca2caaf`, built by native proof run https://github.com/jeong-sik/masc/actions/runs/41820715822. The measured binary SHA-256 is `5f68b8f66a635255027f47e8c81555bcaadcf68d0a5d57e1396870331eaebf5f`.
- Later PR head `8277f7bb473fcfe390d8b0e341a043048a6d834b` changes tests only after that production source.
- Targeted tests: RED `41816089578` → GREEN `41817671919`; RED `41819098923` → GREEN `41820044161`; broader invalidation tests GREEN `41823540544`.

## Comparable measurement

The 80-scroll, 55-row by 200-column PTY scenario measures the chat Build stage:

- mean: **5.06 → 3.86 ms**
- p50: **1.22 → 1.14 ms**
- p95: **16.41 → 11.74 ms**
- p99: **60.00 → 23.23 ms**
- max: **84.37 → 33.22 ms**

The separate initial comparison has p50 2.672291 → 1.14 ms, p95 13.596 → 11.74 ms, and max 33.0645 → 33.22 ms. Its retained-frame counts and live background load differ from the 80-scroll comparison, so it is not an apples-to-apples latency estimate.

Estimated allocations at sampling rate 0.0001 fell from **261.36M to 228.56M words**. The former OpenGraph allocation site at 7.0% is absent from the after profile's reported sites.

## Limits

- Frame Build/Present clocks do not establish causal key-to-physical-display latency.
- Some PTY captures report `observation_complete=false` because the stage cap retained 4096 records and 512 Build frames. This is retained as a measurement limit, not a functional pass.
- The running server and `~/me/.masc` were not reinstalled or restarted for this PR's measurements.
- This bundle does not establish full SSE conversion or performance of the later Memory/Skill cache work.
