# SGR span-copy native PTY comparison

[Comparison 36253209955](https://github.com/jeong-sik/masc/actions/runs/36253209955) completed 600 acknowledged input transitions and six draft checks. Three sessions per arm ran baseline/candidate, candidate/baseline, baseline/candidate. Only the two theme product files differ between native artifacts. Source/interface/test bytes match PR source head `4cb314c5ce` (full SHA and file hashes in source-scope.json). Other PR-base changes are absent from the isolated probe; this is not a current-main comparison.

## Identity and workload

- Observer commit: `304f5f6f67edcb38e3b2ad5da6759d64f73a4983`.
- Helper SHA-256: `4841c61f45457db49dac8afb8a6714a8a9f109671a33e5e9b96b7cf8d4bd39d8`.
- Scenario SHA-256: `2b12d51f3fb64d0a32924804c601a2f9e489729962da303a6049cada1114af55`.
- Baseline: `14c9e1f6488557047e4d77e302fa069e2a88b214`, run `36244725141`, artifact `10907062871`, TUI SHA `f36e87bbf2fb17cc9f1fd25d35e665d93bdc8b8401e7a5f984d6bf75b00006b0`.
- Candidate: `c7bdc04f78e3b6c09abae94e28852b37f8274da7`, run `36252626478`, artifact `10909422480`, TUI SHA `042796d1ed96b8db92766597a6a37e54e2f323d197b930b382ad4765093b45bc`.

The CI runner validated both artifact run/repository/source identities and all binary hashes before execution. Both manifests are `release_validated:false`. Root independently verified the comparison ZIP size/digest and all 27 original members against the extracted files, then matched every receipt to stdout and the summary. Published copies replace only the GitHub macOS checkout prefix with `<CI_CHECKOUT>`; redaction.json records original and published hashes. No measurement values change.

Each session performs 60 roster transitions before Channels setup, then 40 Info transitions after loading 250 alpha channels and one beta channel. Inputs are arrows, page keys, wheel events and Info j/k. The unchanged external observer waits for each expected visible window and completed PTY frame. Its overhead and OS scheduling are included; this does not measure a physical display or production runtime. Different benchmark runs are not pooled.

## Results

Milliseconds; p95 is nearest rank. Counts are per arm.

| Scope | n | Baseline median / p95 / max | Candidate median / p95 / max |
|---|---:|---:|---:|
| All | 300 | 0.322875 / 0.971792 / 2.521125 | 0.305833 / 0.953250 / 2.710542 |
| Roster | 180 | 0.309084 / 0.871958 / 2.493416 | 0.282166 / 0.589458 / 1.552958 |
| Info | 120 | 0.354291 / 1.084916 / 2.521125 | 0.358167 / 1.156750 / 2.710542 |

Overall median and p95 are slightly lower, while the maximum is worse. Roster aggregates are lower, but repetition 2 roster median is worse. Info median, p95 and maximum are all worse; repetition 1 and 2 Info medians are worse, while repetition 3 is lower. Every individual Info action also has a higher aggregate median in the candidate. These mixed observations do not establish an overall latency improvement.

Both maxima occur on the first Info key-down input: baseline repetition 3 at 2.521125ms and candidate repetition 2 at 2.710542ms. The observations do not establish why those tails occurred. All 300 candidate input observations exceed 0.1ms; candidate minimum is 0.229500ms.

Whole-session child CPU seconds include startup/setup/navigation/draft/shutdown and exclude observer CPU. They are not per-action CPU or allocation-volume measurements.

| Repetition | Baseline CPU seconds | Candidate CPU seconds |
|---|---:|---:|
| 1 | 0.156692 | 0.143953 |
| 2 | 0.160444 | 0.159477 |
| 3 | 0.149901 | 0.134185 |
| Median | 0.156692 | 0.143953 |

All three paired whole-session CPU totals are lower, but this three-pair fixture result does not attribute CPU savings solely to strip_sgr or establish a universal gain. Frame build/present reports include setup frames and lack direct input correlation; they cannot assign a particular input tail to build or flush.

## Compiled checks and remaining gates

[Probe focused test 36252628612](https://github.com/jeong-sik/masc/actions/runs/36252628612) passed all 17 theme cases, explicitly including style stripping and the added byte/escape edge assertions. ci.json retains source identity, selected log coordinates and full local log hashes.

PR source fa63f7e5bc passed neither all PR gates nor its focused workflow. [Initial PR run 36252563305](https://github.com/jeong-sik/masc/actions/runs/36252563305) lint failed because the changelog bullet omitted #39349; head 4cb314c5ce fixes that citation, and the changelog check plus all five local stable-doc-input Python tests pass. The release build also failed on main's missing `Rotate_now Authorization_refused` match in runtime_verification.ml, tracked by #39348 and existing fix #39347. The new evidence head requires its own PR gates; no green current-head claim is made. No local OCaml build, production deployment or 0.1ms achievement is claimed.

## Reproduction

```sh
gh workflow run bench-tests.yml --repo jeong-sik/masc \
  --ref perf/tui-corrected-observer-harness-20260926 \
  -f compare_tui=true \
  -f baseline_run=36244725141 -f baseline_artifact=10907062871 \
  -f baseline_commit=14c9e1f6488557047e4d77e302fa069e2a88b214 \
  -f candidate_run=36252626478 -f candidate_artifact=10909422480 \
  -f candidate_commit=c7bdc04f78e3b6c09abae94e28852b37f8274da7 \
  -f repetitions=3 -f input_cycles=10 -f retained_channels=250
```

The observer branch must still resolve to the recorded commit. Raw receipts and per-repetition aggregates support independent recalculation; files.json covers all published files.
