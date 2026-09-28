# Balanced six-pair footer comparison

[Run 36255998183](https://github.com/jeong-sik/masc/actions/runs/36255998183) completed **1,200 acknowledged input transitions and 12 draft checks**, six sessions per arm. It follows the [first three-pair comparison](../comparison/README.md) to assess its observed regression. No observations from the two runs are pooled.

## Fixed identity and protocol

The baseline remains `c7bdc04f78e3b6c09abae94e28852b37f8274da7` (run 36252626478, artifact 10909422480); candidate remains `0278eac5a67d8ec9da06337cae781d96ad702b68` (run 36254942697, artifact 10910511317). The observer remains `304f5f6f67edcb38e3b2ad5da6759d64f73a4983`, with the same scenario/helper hashes and fixture metadata as the first run. The sole input change is repetitions=6. Order alternates baseline/candidate and candidate/baseline, three of each.

Each session has 60 roster transitions, then 40 Info transitions after loading 250 alpha Channels bindings plus one beta binding. All ten action types, expected visible-window acknowledgements, draft assertions and PTY frame completion checks are unchanged. External latency includes observer and OS scheduling overhead; it is not physical-display or production latency.

Artifact metadata, both source/binary identities, all 51 ZIP members, stdout/receipt consistency and summary samples were verified. The candidate footer and two adjusted tests match the PR at `560e43ba03105deb4d1c887082a6d4de33841926`; the only product file changed between artifacts is the footer. The older probe base is not current main. Both binary manifests remain release_validated:false.

## Separate results

Milliseconds; p95 is nearest rank. Counts are per arm.

| Scope | n | Baseline median / p95 / max | Candidate median / p95 / max |
|---|---:|---:|---:|
| All | 600 | 0.327063 / 0.634416 / 12.489916 | 0.302146 / 0.743083 / 11.426792 |
| Roster | 360 | 0.324479 / 0.750583 / 12.489916 | 0.312583 / 0.816375 / 11.426792 |
| Info | 240 | 0.331105 / 0.471250 / 1.568209 | 0.293167 / 0.666833 / 1.305209 |

All three aggregate medians and maxima are lower, while **all three p95s are higher**. Paired medians are lower in 4/6 overall sessions, 4/6 roster sessions and 5/6 Info sessions. The first run had worse overall and Info medians, so that median direction does not reproduce here. The aggregate p95 direction remains worse in both runs. These fixture observations do not establish a reliable latency improvement or prove that the source change caused the tails.

The baseline maximum is repetition 2, roster cycle 4 arrow-down, at 12.489916ms. Candidate maximum is repetition 5, roster cycle 7 page-up, at 11.426792ms. All 600 candidate observations exceed 0.1ms; the candidate minimum is 0.213916ms.

## Whole-session child CPU

CPU totals include startup, setup/navigation, draft checks and shutdown and exclude observer CPU. They are not footer-specific CPU or allocation-volume measurements.

| Pair | Baseline seconds | Candidate seconds |
|---|---:|---:|
| 1 | 0.140278 | 0.145183 |
| 2 | 0.137694 | 0.137139 |
| 3 | 0.118541 | 0.118079 |
| 4 | 0.119548 | 0.117791 |
| 5 | 0.120764 | 0.117628 |
| 6 | 0.127980 | 0.113158 |
| Median | 0.124372 | 0.117935 |

Five of six paired CPU totals are lower. This does not override the inconsistent latency results or attribute a CPU gain solely to the footer. Build/present reports include setup frames and are not correlated to each measured input.

## Disposition

PR #39371 remains draft. The two completed runs leave the proposed latency benefit unproven, with worse aggregate p95 in both. No further identical repetitions are requested. A future source revision needs its own comparison; these results cannot be presented as proof for it. Compiled footer/Identity/key tests and PR gates remain separate obligations.

## Receipts and reproduction

`raw/` retains all 51 original artifact members except for the GitHub macOS checkout prefix in the three identity/summary JSONs, which becomes `<CI_CHECKOUT>`. `redaction.json` records original and published hashes. Artifact ZIP digest checks the original files; parent `files.json` checks published bytes.

Reuse the first comparison's workflow command with the same artifact IDs/commits and `-f repetitions=6`. The observer branch must resolve to the recorded commit. No local OCaml build, live deployment, physical-display result, or 0.1ms completion is claimed.
