# Coding grader boundary measurements

The production grading helper at source `dca2013ebf915a37631a5d95d305d226928c1b6f`
was invoked with the real Node image recorded in `observations.json`. For each
Node case, the candidate's `check.js` was replaced with `process.exit(0)`.
The protected grader rejected both candidates while their broken implementation
hashes remained unchanged. Overlaying each reference implementation produced
exit zero through the same protected grader. The four per-stage receipts bind
the captured input files and image ID; the corresponding logs contain real
container output.

This proves the Node oracle restoration and actual isolated grading path. It
does not prove a live MASC or provider episode, arbitrary solution correctness,
or a microVM grader. This coding driver selects Docker only. The generic
Python boundary probe additionally exercises verify/regression/build against
one snapshot, rejects candidate symlinks, and refuses stale experiment inputs:

```sh
python3 scripts/tests/test_coding_eval_boundary.py --docker-image python:3.12-slim
```

MicroVM command execution is a separate guest/shim path in MASC. Its evidence
reader copies artifact bytes, and that alone does not execute a candidate.
Moving a future microVM verifier to the host would recreate the same boundary
error; no such backend is selected or attested by this driver.
