# Frame buffer capacity comparison

The source replaces two `String.length (Buffer.contents buf)` capacity reads
with `Buffer.length buf`. OCaml's former operation copies the buffer, while
`length` returns the same current position. This removes those copies in source.
Allocation volume was not measured, and this run does **not** demonstrate an
overall latency or CPU improvement.

## Identity and method

[Paired benchmark 36245415137](https://github.com/jeong-sik/masc/actions/runs/36245415137)
passed all 600 input transitions and six draft checks. Three sessions per arm
ran in before/after, after/before, before/after order on one macOS runner.

- Observer: `304f5f6f67edcb38e3b2ad5da6759d64f73a4983`.
- Helper: `4841c61f45457db49dac8afb8a6714a8a9f109671a33e5e9b96b7cf8d4bd39d8`.
- Scenario: `2b12d51f3fb64d0a32924804c601a2f9e489729962da303a6049cada1114af55`.
- Baseline: `9adb139dd3aabcb67d7bdf35184f21915c401e41`, artifact `10906509317`,
  TUI SHA-256 `815bdbfd53d13c64f8f4f1fe84da5a23155c91764da8d8365b57d9b964326854`.
- Candidate: `14c9e1f6488557047e4d77e302fa069e2a88b214`, artifact `10907062871`,
  TUI SHA-256 `f36e87bbf2fb17cc9f1fd25d35e665d93bdc8b8401e7a5f984d6bf75b00006b0`.
- The only product diff is the two capacity reads in `masc_tui_render_prim.ml`;
  a changelog is the other changed file. Both integration reviewers checked
  preservation of the measured footer baseline and identity with PR source.
- The runner verified artifact source/run/repository, manifests and all binary
  hashes before execution. Both manifests report `release_validated:false`.
  Root verified the comparison ZIP digest and reconciled all receipt samples,
  stdout, identities, fixture metadata and summary arrays. Two independent
  reviewers reached the same result. All 27 raw files are retained unchanged;
  `files.json` records their hashes.

Each session has 60 roster transitions **before** Channels fixture setup and
40 Info transitions after loading 250 alpha channels plus one beta channel.
The inputs are acknowledged against expected terminal windows and completed
PTY frames. The external observer is unchanged for both arms; it is not the
older helper stored inside either product checkout. Measurements include OS
scheduling and observer overhead. They do not measure a physical display or
production runtime. Results from different benchmark runs are not pooled.

## Measured results

Milliseconds; p95 is nearest rank. Counts are per arm.

| Scope | n | Baseline median / p95 / max | Candidate median / p95 / max |
|---|---:|---:|---:|
| All | 300 | 0.356980 / 1.145333 / 16.765500 | 0.363167 / 1.148750 / 15.993209 |
| Roster | 180 | 0.331729 / 0.834041 / 2.592625 | 0.365333 / 1.517083 / 15.993209 |
| Info | 120 | 0.379375 / 1.383209 / 16.765500 | 0.363167 / 0.773833 / 3.232042 |

**Overall median and p95 increased. Roster median, p95 and max increased.**
Info aggregates improved, but repetition 1's Info median worsened. The candidate
maximum was repetition 1, cycle 7, arrow down. The baseline maximum was repetition
2's Info wheel down. The data does not establish why either tail occurred.
All 300 candidate inputs exceeded 0.1ms; candidate minimum was 0.235584ms.

Whole-session child CPU seconds include startup, setup, navigation, draft and
shutdown, and exclude observer CPU. They are not per-action CPU measurements.

| Repetition | Baseline | Candidate |
|---|---:|---:|
| 1 | 0.222741 | 0.199136 |
| 2 | 0.159257 | 0.183293 |
| 3 | 0.177504 | 0.161104 |
| Median | 0.177504 | 0.183293 |

The CPU sum fell but its median rose. These mixed observations support neither
a consistent CPU gain nor a universal tail bound. Frame build/present reports
include setup frames and lack direct input correlation; they cannot attribute
the 15.993209ms input delay to a particular build or flush.

## Verification and reproduction

PR source head `feb51ec1c96f1f8e09cadbebbcb2d05f46f96691` passed all five
[PR gates 36244439071](https://github.com/jeong-sik/masc/actions/runs/36244439071)
and [focused checks 36244483608](https://github.com/jeong-sik/masc/actions/runs/36244483608).
The comparison candidate passed [focused checks 36244726334](https://github.com/jeong-sik/masc/actions/runs/36244726334).
Both focused logs show 33 agenda + 85 Activity-pane + 21 presenter cases and
the tab-strip PTY scenario. No local OCaml build was performed. An evidence-only
commit after that PR source head requires its own PR gates.

The dispatched command was:

```sh
gh workflow run bench-tests.yml --repo jeong-sik/masc \
  --ref perf/tui-corrected-observer-harness-20260926 \
  -f compare_tui=true \
  -f baseline_run=36243647589 -f baseline_artifact=10906509317 \
  -f baseline_commit=9adb139dd3aabcb67d7bdf35184f21915c401e41 \
  -f candidate_run=36244725141 -f candidate_artifact=10907062871 \
  -f candidate_commit=14c9e1f6488557047e4d77e302fa069e2a88b214 \
  -f repetitions=3 -f input_cycles=10 -f retained_channels=250
```

The dispatch branch must still resolve to the recorded observer commit to
reproduce this experiment. Runtime deployment and the 0.1ms goal remain unproved.
