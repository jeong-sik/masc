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
