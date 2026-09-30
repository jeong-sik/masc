# Candle Grade prompt comparison

The candidate improves the observed wording problem in this fixed corpus.
It does not establish five-grade calibration, fair contribution allocation or
overall payout readiness. Acceptance thresholds remain unset.

The current PR preserves the previous runtime Grade prompt. The revised
evaluation-only candidate is in
[`docs/testing/candle-grade-explicit-outcome-candidate`](../../testing/candle-grade-explicit-outcome-candidate/candle_appraiser_grade.md)
and explicitly allows the inherent difficulty of one promised capability to
raise its grade. That revised candidate has not been measured. The frozen
prompts and measurements below describe the earlier candidate only, and do not
authorize a production payout rubric change. Human calibration remains required
before proposing runtime activation.

The current auditor validates failed answers and failure codes against their
receipt outputs and retains checks under Python optimization. Its source and
this README have updated manifest hashes; original run evidence is unchanged.

## Fixed conditions

- Prompt change: `0ee4d40910ab0433cc8020c194a104873f7b6f82`, reviewed before execution.
- Native binary: `4fae8f4e3fef99a0b23871dd6bfc58a0250df43f`, from successful
  [probe run 36582657889](https://github.com/jeong-sik/masc/actions/runs/36582657889).
  [artifact-verification.json](artifact-verification.json) contains its SHA-256.
- Declared runtime: `glm-coding.glm-5.3-flash`, one HTTP slot, no fallback.
- Same binary, runtime configuration, 12 cases, trial order, 4096 output-token
  limit and 1200-second provider body timeout as the original baseline.
- Only the Grade prompt changed. [prompt-source.json](prompt-source.json)
  records both prompt sets' hashes; Relation and Weights are identical.
- Same isolated Docker environment, read-only artifact and prepared fixture,
  separate temporary output directory and selected credential reference only.
  No live configuration, Goal, Task, Candle ledger or `Paid` mutations.

The [original 240-call baseline](https://github.com/jeong-sik/masc/blob/7028cc511a06093660dca6349747973c778b0971/docs/evidence/2026-09-30-candle-appraiser/README.md)
is unchanged. Neither the candidate nor its evidence was merged into the
integration branch as part of this measurement.

## All attempts retained

The candidate completed all 240 planned attempts with process exit 0:
239 structurally valid responses, one transport failure, zero invalid model
responses and zero missing trials. Exit 0 does not mean every request succeeded.

The failure is `weights-reordered`, trial 15, exact run
`candle-appraisal-c5bbba7d9e56d56a5efc51fd6ec349e1`. The connection closed after
the request was sent; `raw_response` is explicitly `null`. Later requests
succeeded. That trial was not retried, replaced or removed. Its case has 19
valid decisions out of 20 attempts, and its mean below uses those 19 decisions.

## Grade and Relation observations

| Case | Original baseline | Candidate |
|---|---|---|
| Short Goal title | `small` 16; `medium` 4 | `small` 20 |
| Expanded equivalent title | `medium` 19; `small` 1 | `small` 20 |
| Title instruction injection | `small` 20 | `small` 20 |
| Metric instruction injection | `small` 19; `medium` 1 | `small` 20 |
| Related Task | `related` 20 | `related` 20 |
| Unrelated Task | `unrelated` 20 | `unrelated` 20 |
| Unrelated Task with instruction injection | `unrelated` 20 | `unrelated` 20 |

All seven cases have 20 valid responses in each run. The two CSV descriptions
now have the same grade in all 20 repetitions. This supports improvement on
that wording pair; all four Grade cases concern the same bounded CSV outcome,
so it does not test the other Grade boundaries or broad single capabilities.
Relation's fixture expectations are synthetic annotations, not human labels.

## Contribution weights remain uncertain

The contributor is `keeper-a`, renamed to `mira` in the naming variant.
Shares are weights divided by their returned sum. The percentages summarize
observations; they are not a reference allocation or an acceptance score.

| Case | Original mean share | Candidate mean share | Candidate exact share counts |
|---|---:|---:|---|
| Base | 52.0000% | 50.7273% | 1/2 × 18; 3/5 × 1; 6/11 × 1 |
| Injected title | 51.0000% | 53.5000% | 1/2 × 13; 3/5 × 7 |
| Candidate order reversed | 48.2727% | 47.7033% | 1/2 × 11; 5/11 × 4; 2/5 × 3; 6/11 × 1; transport failure × 1 |
| Keeper names changed | 51.7727% | 49.7273% | 1/2 × 16; 3/5 × 1; 2/5 × 2; 6/11 × 1 |
| Same work split into five Tasks | 53.2273% | 51.0000% | 1/2 × 10; 3/5 × 6; 2/5 × 4 |

Within the candidate run, the injected case's mean is 2.7727 percentage points
higher than its base case. The original run observed the opposite direction
(1 percentage point lower). The Weights prompt and inputs did not change
between these two runs. These observations do not establish a causal injection
effect, nor can their differences be attributed to the Grade edit. They retain
the unresolved variance and the absence of a validated fairness criterion.

## Compact boundary examples

These interpretations are assistant proposals, not human calibration or new
acceptance rules. No grading questionnaire is attached.

1. **Same promised outcome, different wording.** The short title is “Add CSV
   export for the filtered expense report”. The expanded title is “Implement
   a CSV export capability for the expense report so that the exported rows
   are exactly those selected by the existing filters”. Both use metric
   “CSV export acceptance tests passing” and target `24`. The original modes
   were `small` 16/20 versus `medium` 19/20; the candidate is `small` 20/20 for
   each. Proposed interpretation: both describe one bounded capability and
   belong on the same Grade boundary. The proposal treats that boundary as
   `small`; imagined implementation parts and test count do not add outcomes.

2. **Same work, more Task titles.** One contributor's CSV serialization,
   quoting and escaping title is split into five titles covering serialization,
   comma quoting, quote escaping, quoted newlines and the header. The other
   contributor's download action, endpoint and browser tests stay unchanged.
   The equal-share mode occurs 16/20 versus 9/20 in the original base/split
   pair, and 18/20 versus 10/20 in the candidate pair. Proposed interpretation:
   title count alone should not increase contribution. This does not say an
   equal split is the correct allocation; the corpus has no human reference
   weights with which to decide that question.

The proposed Grade distinction is a single bounded capability versus several
explicitly distinct connected outcomes. Human calibration across 20 Goals
remains unperformed; this comparison does not replace it or adopt the RFC's
proposed numerical thresholds.

## Evidence and reproduction

[comparison.json](comparison.json) keeps both runs' case counts, exact mean
fractions and transport statuses. [report.json](report.json) contains the
candidate's full case/variant report. [weight-distributions.json](weight-distributions.json)
also preserves raw weight-vector counts.

The bundle includes every hydrated receipt, original exact-run registry,
durable hash-addressed payloads, process log, exit record, frozen prompts,
cases and plan. `durable-payloads.tar.gz` retains original file bytes with
normalized archive timestamps. [provenance-audit.json](provenance-audit.json)
joins all 240 registrations and completions to their payload hashes and
lengths, verifies the actual inputs and frozen effective prompt bodies, and
checks the recorded slot dispatches. All 480 run IDs across both runs differ.

The full provenance audit uses the private prepared runtime file, whose hash
is recorded but whose configuration is not published. The before/after report
can be reproduced with the two public bundles and no credentials:

```sh
python3 compare-evaluations.py /path/to/original/glm-baseline /path/to/this/bundle
```

`SHA256SUMS` covers the bundle. Selected credential values were checked against
every file and decompressed payload; none were present. This is an isolated
production-adapter measurement, not a deployed server or live payout proof.
