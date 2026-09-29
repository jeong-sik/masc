# Input readiness comparison: candidate2 to candidate3

[CI run 36041115080](https://github.com/jeong-sik/masc/actions/runs/36041115080)
passed on comparison workflow `658bd75ee6038f76be8a111bc2cd8fc8b5ebc42d`.
Artifact `10826488659` contains these 27 raw files. The downloaded summary was
checked for exact equality with the CI log. Independent review found no mismatch.

- Baseline: `8e2224bde96ba4aeddb79bdbea79ff03482ee1e3`, Release run
  `36031132761`, artifact `10822896321`, TUI SHA-256
  `3ec318b6b5d4134d7748d4c255634757ae4c1276e0a79b41005b6922317db289`.
- Candidate: `dfe4e9955627660e39947d5917e311c2091a24c7`, Release run
  `36039010105`, artifact `10826796900`, TUI SHA-256
  `117927d1201f715048bea3ab2f808e0fb0f3849b4db0b71dd890a79a2df39be3`.
- The only product-code difference under `bin/` and `lib/` is the input decoder
  wrapper: owner Eio fiber instead of a system-thread dispatch. Both candidates
  retain the 16ms successive-input frame policy.
- One macOS ARM runner, three repetitions per binary, order B/C, C/B, B/C.
  All 60 acknowledged transitions and six draft-burst checks passed.

## Observations

Baseline observations span **0.564167–138.831709ms**, candidate observations
**0.504209–21.430917ms**. Per-action medians in milliseconds:

| Action | Baseline | Candidate |
| --- | ---: | ---: |
| arrow down | 0.788417 | 0.743000 |
| arrow up | 76.279917 | 18.883334 |
| wheel down | 76.173541 | 18.654500 |
| wheel up | 71.899042 | 18.309375 |
| page down | 84.345458 | 18.299667 |
| page up | 73.279584 | 18.591750 |
| detail key down | 0.589333 | 0.559667 |
| detail key up | 34.477625 | 18.579500 |
| detail wheel down | 32.530458 | 18.733792 |
| detail wheel up | 100.334583 | 18.189875 |

Candidate frame-build p95 per session: 0.58, 0.77, 0.66ms. These histograms are
not correlated with individual input timestamps. This run supports reduced long
input waits for the fixture. It does not prove physical display latency,
production deployment, CPU improvement, all actions or the **0.1ms** objective.
The continued ~18ms median for successive inputs remains above the target.

The separate 600-transition attempt (36042758515) failed during initial roster
setup in its second candidate run. Its partial results are not pooled into this
complete 60-transition comparison; see the repeated-input evidence document.
