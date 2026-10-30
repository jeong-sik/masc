# Footer parse-once native PTY comparison

[Comparison 36255472077](https://github.com/jeong-sik/masc/actions/runs/36255472077) completed 600 acknowledged input transitions and six draft checks. Three sessions per arm ran baseline/candidate, candidate/baseline, baseline/candidate. Only the footer product file differs between the native artifacts; it and both adapted tests match PR source head `c7d67a745f40d1669413e6a5c50349bc2e61f5d4`. Other PR-base changes are absent from the isolated probe; this is not a current-main comparison.

## Identity and workload

- Observer: `304f5f6f67edcb38e3b2ad5da6759d64f73a4983`.
- Helper SHA-256: `4841c61f45457db49dac8afb8a6714a8a9f109671a33e5e9b96b7cf8d4bd39d8`.
- Scenario SHA-256: `2b12d51f3fb64d0a32924804c601a2f9e489729962da303a6049cada1114af55`.
- Baseline: `c7bdc04f78e3b6c09abae94e28852b37f8274da7`, run `36252626478`, artifact `10909422480`, TUI SHA `042796d1ed96b8db92766597a6a37e54e2f323d197b930b382ad4765093b45bc`.
- Candidate: `0278eac5a67d8ec9da06337cae781d96ad702b68`, run `36254942697`, artifact `10910511317`, TUI SHA `7ff18ff61078459de4bcb13a6510b85b87e91e1a5d02b0e6d3442416cd58e581`.

The CI runner verified both artifact run/repository/source identities and all binary hashes before execution. Both manifests are `release_validated:false`. Root also independently downloaded and verified both binary artifacts, and verified the comparison ZIP size/digest and all 27 original members against the extracted files. Every receipt was matched to stdout and summary. Published copies replace only the GitHub macOS checkout prefix with `<CI_CHECKOUT>`; redaction.json keeps original and published hashes separate.

Each session performs 60 roster transitions before Channels setup, then 40 Info transitions after loading 250 alpha channels and one beta channel. Inputs are arrows, page keys, wheel events and Info j/k. The same observer waits for each expected visible window and completed PTY frame; its overhead and OS scheduling are included. This does not measure physical-display latency or the production runtime. Different benchmark runs are not pooled.

## Results

Milliseconds; p95 is nearest rank. Counts are per arm.

| Scope | n | Baseline median / p95 / max | Candidate median / p95 / max |
|---|---:|---:|---:|
| All | 300 | 0.424646 / 0.978000 / 3.027250 | 0.460896 / 1.308958 / 6.478875 |
| Roster | 180 | 0.447771 / 1.085583 / 3.027250 | 0.427666 / 1.771416 / 6.478875 |
| Info | 120 | 0.408021 / 0.798292 / 1.042916 | 0.539292 / 1.107875 / 2.749583 |

Aggregate overall median, p95 and maximum are worse. Roster median is lower but its p95 and maximum are worse. Info median, p95 and maximum are all worse. Overall and roster medians are lower in repetitions 1 and 3, while Info median is lower only in repetition 1. These observations do not demonstrate a latency improvement.

The baseline maximum is repetition 3 roster cycle 4 arrow-up at 3.027250ms; the candidate maximum is repetition 2 roster cycle 3 arrow-down at 6.478875ms. The receipts do not establish why the tails occurred. All 300 candidate observations exceed 0.1ms; the candidate minimum is 0.221584ms.

Whole-session child CPU includes startup, setup, navigation, draft checks and shutdown. It excludes the observer but is not per-action CPU or an allocation measurement.

| Repetition | Baseline CPU seconds | Candidate CPU seconds |
|---|---:|---:|
| 1 | 0.258053 | 0.186546 |
| 2 | 0.156317 | 0.167066 |
| 3 | 0.185366 | 0.172440 |
| Median | 0.185366 | 0.172440 |

Two of three paired CPU totals are lower. That mixed, whole-session result does not establish footer-specific CPU savings. Frame build/present reports include setup frames and cannot assign a specific input tail to build or flush.

## Disposition and verification

PR #39371 was returned to draft after this comparison because the proposed optimization has not demonstrated a latency benefit and its aggregate tails worsened. A separate six-pair run with the same artifacts, inputs and observer is requested to assess whether the regression reproduces with balanced execution order; its observations must remain separate from this run.

Focused compiled footer/Identity/key tests at PR source c7d67 (run 36254888916) and probe 0278 (run 36254944303) were still queued at this evidence boundary. A successful benchmark workflow is not their test result. No local OCaml build, production deployment, universal speedup or 0.1ms achievement is claimed.

## Reproduction

```sh
gh workflow run bench-tests.yml --repo jeong-sik/masc \
  --ref perf/tui-corrected-observer-harness-20260926 \
  -f compare_tui=true \
  -f baseline_run=36252626478 -f baseline_artifact=10909422480 \
  -f baseline_commit=c7bdc04f78e3b6c09abae94e28852b37f8274da7 \
  -f candidate_run=36254942697 -f candidate_artifact=10910511317 \
  -f candidate_commit=0278eac5a67d8ec9da06337cae781d96ad702b68 \
  -f repetitions=3 -f input_cycles=10 -f retained_channels=250
```

The observer branch must still resolve to its recorded commit. Raw receipts and aggregates support independent recalculation; the parent files.json covers all published files.
