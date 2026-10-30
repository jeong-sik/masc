# PTY observer readiness and measured flush delays

## Observation and controlled change

The previous same-frame diagnostic found 22–25ms inside flush on the N250
retained-Channels fixture. The TUI binary used here is exactly the same artifact:
source `53f784617c1867b3ecadb300bc8bd1d0844dd233`, build `36239521218`, artifact
`10905313235`, TUI SHA-256
`88b23dce786b5721e8ac1c5730b9735088141e6324af1e677d9d4ce92dee2bc8`.
ZIP digest and all three binaries were verified against the GitHub metadata and
manifest before execution. The manifest says `release_validated: false`.

`wait_for_fixture_state` reads available terminal bytes then sleeps for 20ms
while a fixture condition is pending. A new output can fill the PTY while that
observer sleeps. The proposed helper uses `select` with the same 20ms maximum,
so output readiness wakes the reader. Conditions with no terminal output retain
the existing polling cadence. It adds no product timeout or latency threshold.

The helper at measured PR head `3d9e927a2c2d0c91aa11816ece1f76f1d572b712`
is byte-identical to the one measured in `reader-wait/`, SHA-256
`4841c61f45457db49dac8afb8a6714a8a9f109671a33e5e9b96b7cf8d4bd39d8`.
The original helper matches both main `f093b96cb86d21c0c2370e1b4b4d083e842eca26`
and harness `4d31a42ca9c948d9c1605625dd45c2b6c122d0a3`. The runner regenerates
both helper variants from that pinned harness; their only difference is in
`helper.diff`. Large helper copies are omitted from the evidence directory.

Later integration with main `0dcd3e8467fbd9217d8a8de2f92218afbdac5dfa`
retains main's wait-stall diagnostics. The current helper therefore has a
different full-file hash; its diff from that main remains exactly the one-line
sleep-to-select change. The observations below belong to the pinned measured
helper, not to a rerun of the newly combined helper.

## Experiments

Both comparisons run sequentially on one local macOS ARM host. Each alternates
baseline/candidate, candidate/baseline, baseline/candidate. Each session performs
100 acknowledged transitions, a checked draft, and retains 250 synthetic channel
names. Preflight hashes and action sequences match. No latency threshold decides
PASS. `verified-aggregates.json` is recomputed from raw receipts.

1. **Screen reconstruction hypothesis:** only the Channels readiness callback's
   full-history screen decode was reduced to the suffix from the latest complete
   clear-screen. A separate 100-transition oracle checked that both decoded
   screens were identical. All 600 comparison transitions passed, but the
   intervention did not lower the maximum flush durations. This hypothesis is
   not adopted; that source change is not in the PR.
2. **Readiness wait:** the same scenario and binary use either the original
   helper's sleep or the proposed helper's readability wait. An assertion checks
   which helper Python actually imported. All 600 comparison transitions and six
   draft checks passed.

| Observer | Maximum flush, ms, per session | Median of session maxima, ms |
|---|---|---:|
| Whole-history decode | 23.265 / 0.210 / 25.301 | 23.265 |
| Decode from latest clear-screen | 24.357 / 24.944 / 25.309 | 24.944 |
| Fixed sleep (separate experiment) | 25.416 / 25.373 / 25.395 | 25.395 |
| Wait for readable PTY | 0.292 / 0.302 / 0.279 | 0.292 |

The latter intervention supports attributing most of this local synthetic
workload's 25ms flush tail to observer waiting. It is not a product speedup.
Input medians remain 17.456ms with sleep and 17.393ms with readiness because
this main-based diagnostic binary does not include the separate drained-input
and deferred-tab improvements. The 0.1ms objective remains unmet.

## Limits and verification

Raw stdout, stderr, receipts, timing files, source variants/diffs, runner,
identity and summary are retained. All stderr files are empty. No observations
were dropped; the low 0.210ms baseline session remains visible. The oracle's
extra work is outside the comparison. The two experiments are not pooled.

This establishes a local observer effect on this unchanged binary. It does not
establish the cause of the earlier 165ms CI observation, physical display
latency, a live production improvement, or a universal bound for flush. Source
syntax and seven scenario-selection tests pass, including the selection tests
after main integration. PR run `36241241318` passed all five gates on measured
head `3d9e927a2c2d0c91aa11816ece1f76f1d572b712`; that PR was merged as main `1c717324a5e505b5088e0f8b8cf671ebf430d17f`.
The merged helper also passed a separate 100-transition N250 PTY smoke and
one checked draft. Its full-file SHA-256 is
`cdd6271f169c806f6ba19fd2506daad4a52b33d7daddbb0ef0a7df8f884abe66`.
This follow-up evidence update is carried by #39263; no new controlled latency
comparison of the merged helper is claimed. Independent adversarial and response reviews reconciled both
experiments. No local build, installation or server restart occurred.
