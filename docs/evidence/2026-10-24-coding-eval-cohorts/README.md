# Coding evaluation cohort and cost correction

The former report grouped every row by `case_id`, even when the rows came from
different configured models. Two five-episode model groups, one entirely green
and one entirely red, became one pass@1 of 0.5. The corrected report produces
separate results of 1.0 and 0.0. Provider, model, memory mode, experiment digest,
and case now determine the statistical sample. Repeated run IDs and repeat
indices are refused within a cohort, while separate experiments may reuse them.

Provider/model are producer configuration labels. This evidence does not attest
which provider weights a live runtime selected after failover. The decoder
requires the producer's lowercase SHA256 `experiment_digest` and one of the five
declared memory modes; older unidentified rows are refused rather than guessed.

Every case and cohort reports cost coverage, an explicitly known subtotal, and
a full total only if every episode's cost was observed. One green episode priced
at USD 1 and one red episode with an unreported price formerly gave a case total
of USD 1; the full total is now unknown. When the red episode is priced at USD 2,
the empirical cost per solved acceptance is USD 3. The denominator counts green
episode acceptances, including repeated acceptance of the same case; it does
not estimate unique delivered tasks. Missing costs or no successful acceptance
produce `null`, and failed episodes remain in the numerator. The global artifact
contains spending coverage/totals but no pooled performance or solved-price rate.

## Verification scope

`verify_report.py` compiles and runs the complete actual `Eval_harness`,
`Coding_eval_case`, `Coding_eval_report`, and CLI source modules from base commit
`8eac5c07c290d134a9ef6acb1e298584bf9a1366` and the working candidate. It also runs
13 selected tests from the actual `test_coding_eval_cases.ml` source. Unrelated
runtime dependencies are explicit ports that fail if called; the Trajectory
outcome type and formatter are extracted from the real source. These ports do
not implement any reporting, grouping, scoring, cost calculation, or assertions.

This is bounded actual-source execution, not a native MASC build or evidence of
live provider, sandbox, grader, deployment, or full CI behavior. No Dune command
is invoked. The unrelated pre-existing fragile-match warning in
`coding_eval_case.ml` is retained in the receipts; changed report and evaluation
modules plus the test source compile with warnings treated as errors.

Reproduce with installed OCaml, ocamlfind, yojson, re.pcre, and Alcotest:

```sh
python3 docs/evidence/2026-10-24-coding-eval-cohorts/verify_report.py \
  --repo "$PWD" --out /tmp/masc-coding-cohort-check-new-directory
```

The output directory must not already exist. The final recorded run used
`/tmp/masc-coding-cohort-probe-20261024-r6`. `observations.json` records its
measured before/after results; `source-manifest.json` records exact source and
corpus declaration hashes, compiler version, ports, and warning policy.
`regression-run.txt` contains the focused test receipt. No model costs were
measured in this probe; the input prices are explicit fixtures.
