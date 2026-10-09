# Explicit memory admission growth probe

This experiment measures the storage boundary of `keeper_memory_write` before
changing write admission. It uses three isolated synthetic Keepers, each with
200 writes:

| Cohort | Input | Designed final knowledge branches |
|---|---|---:|
| Exact reobservation | Identical approval requirement each time | 1 |
| Repeated receipts | Same unchanged requirement with a different check number | 1 |
| Independent rules | Approval requirements for different releases | 200 |

The branch counts describe the fixture, not a semantic evaluator's conclusion.
No Librarian or model provider is started. Each call uses the real write handler
and ordinary current store under a temporary workspace; production memory is
not read. The probe verifies the resolved store path before writing.

The executable emits `MEMORY_WRITE_GROWTH` JSON rows after writes 1, 29, 30, 31,
100 and 200. Each row records the complete input-sequence hash, current fact
count, revision, serialized fact-array bytes, cumulative write-receipt outcomes
and effective category limits. These are 18 samples across the three cohorts.

A passing test establishes that the experiment ran and its write receipts were
successful. It does not establish semantic deduplication or enforce today's
observed fact counts as expected behavior. This lets the same inputs measure a
future pending-admission implementation without making immediate admission a
regression contract.

`serialized_fact_bytes` is neither provider tokens nor total disk use. Pending
queue storage, source-bound writes, replacement/retraction, concurrent Librarian
work and full prompt construction are outside this probe. A count above the
configured working-set target describes immediate write behavior without a
cleanup worker; it does not prove that a running Keeper never consolidates.

Request the isolated measurement on the exact branch being investigated:

```sh
gh workflow run test.yml --repo jeong-sik/masc \
  --ref feat/deferred-memory-write-20261009 \
  -f suite=test_keeper_memory_write_growth_probe -f minimal=true
```

Keep the successful test's captured/verbose output and the run's actual head SHA.
Extract only rows starting with `MEMORY_WRITE_GROWTH` from the test output when
comparing revisions. Compare all three cohorts: compressing truly independent
rules is a failure even if it reduces the count.

## Measured baseline

[Run 37804633441](https://github.com/jeong-sik/masc/actions/runs/37804633441)
succeeded at `c304c83d51e66fae8af16da88e6449133ff410b2`: the growth experiment
emitted all 18 samples, and the accompanying absorption suite passed 53 tests.
The earlier run37803674163 failed compilation before executing the experiment;
its missing unavailable-reason branch was repaired in parent #41947.

| Writes | Exact same sentence: current facts | Same rule, different check number: current facts | Independent rules: current facts |
|---:|---:|---:|---:|
| 1 | 1 | 1 | 1 |
| 29 | 1 | 29 | 29 |
| 30 | 1 | 30 | 30 |
| 31 | 1 | 31 | 31 |
| 100 | 1 | 100 | 100 |
| 200 | 1 | 200 | 200 |

All cohorts reached revision 200 and reported 200 `persisted_current_snapshot`
receipts. At the final checkpoint their fact-array sizes were respectively 255,
62,847 and 52,061 bytes. Exact reobservation changes the revision even while the
fact count stays one. Timestamp serialization means bytes are not a deterministic
fixture expectation.

The effective limit receipt explicitly reports `enforcement=advisory`, category
cap 30 and per-category target 30. At 200 distinct sentences there is one category
with 170 excess items. Thus the ordinary write handler does not enforce a hard
30-item ceiling. This experiment does not run the asynchronous cleanup worker.

The repeated-check cohort is designed to contain one unchanged rule. Its growth
shows that exact-byte identity alone does not consolidate this repetition at the
write boundary. The independent-rule cohort must remain a separate comparison:
count reduction alone cannot establish that useful knowledge was preserved.
Deferred admission is not implemented by this experiment.
