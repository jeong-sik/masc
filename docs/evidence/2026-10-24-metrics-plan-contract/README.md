# Metrics plan contract repair

Integrated candidate `7501aec032012869d8b979e0d14e1a9a9464ace7` completed
26 of 29 explicitly selected native suites successfully in run
[40078581651](https://github.com/jeong-sik/masc/actions/runs/40078581651).
The run failed; it is not full regression evidence.

`test_keeper_tool_plan` exposed a real consumer defect: the metric descriptor
included `enum`, which the deliberately closed composable schema language
rejects. Remove that unsupported keyword from the two primitive descriptors.
The typed producer and strict dashboard parser still own the allowed values;
the plan language is unchanged.

`test_metrics_store_eio` stopped while trying to serialize its invalid NaN
fixture, before reaching the source reader. Keep the writer rejection check,
and supply corrupt raw NaN bytes directly to the reader scenario. This does
not relax production validation or change serialization.

Reproduce the bounded before/after source execution:

```sh
python3 docs/evidence/2026-10-24-metrics-plan-contract/verify_contract.py \
  --repo "$PWD" --out /tmp/masc-metrics-contract-new-directory
```

The root integration session independently executed this probe. Both metric
contracts change from rejection to acceptance. Seven invalid source rows
reach the reader and are rejected; NaN reports `start time must be finite`.
Valid zero-duration observations, two producer shapes and two malformed-output
controls remain checked. The source manifest records extracted fragments and
the explicit ordinary-file read port. This is actual validator/descriptor and
metric reader source execution, not the full plan/ownership path or a native
suite rerun. The native follow-up must be recorded separately.
