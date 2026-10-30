# Keeper claimable membership measurement

Baseline production source: `e09b9c981afb16843c071366c5d9724fd4026d96`. Candidate source and executable hashes are in [validation.json](validation.json). Both executables use the identical committed native runner.

The source used a linear scan of blocked scopes for each queued operation. The candidate builds a typed immutable Set after the same complete semantic-record validation. Four consumers use membership; queue order, retry deadlines, manual priority and all writes retain their existing rules. The Set belongs only to one read/transaction and is never persisted or reused at another observation time.

## Measurement

All fixtures are synthetic, seeded through public Store APIs. Each contains N cooling retry continuations and one fresh request. `prefix / 5` skips the cooling prefix; `prefix / 100` observes those retries at their exact eligibility boundary; `front / 5` puts the fresh request first using the public manual-priority operation. No production queue was modified.

Three paired rounds ran AB, BA, AB. Every case warms five reads, then measures 41 reads with a monotonic Mtime counter. Each read includes semantic decoding/validation, blocked-set construction, SQL selection and membership. A full major collection immediately before each read is outside the timer/allocation counter; any collection during a read is inside. These are warm synchronous reads, not steady-state GC, model productivity, HTTP, TUI or end-to-end latency.

The table reports the median of three per-round p50s, not a pooled p50. Negative changes are faster. Small absolute differences and controls show noise; this is not a universal speedup claim. All per-round p50/p95/allocation summaries are preserved alongside the manifest. Individual sample timings are not logged.

| Deferred rows | Layout / time | Before ms | After ms | Change | Before allocated bytes | After allocated bytes |
|---:|---|---:|---:|---:|---:|---:|
| 0 | prefix / 5 | 0.040583 | 0.040625 | +0.1% | 7440 | 7400 |
| 0 | prefix / 100 | 0.038625 | 0.050417 | +30.5% | 7440 | 7400 |
| 0 | front / 5 | 0.040333 | 0.047709 | +18.3% | 7440 | 7400 |
| 1 | prefix / 5 | 0.084708 | 0.082042 | -3.1% | 51504 | 51464 |
| 1 | prefix / 100 | 0.081666 | 0.074958 | -8.2% | 45672 | 45632 |
| 1 | front / 5 | 0.068333 | 0.071042 | +4.0% | 45712 | 45712 |
| 32 | prefix / 5 | 0.721834 | 0.734125 | +1.7% | 1417488 | 1422608 |
| 32 | prefix / 100 | 0.647292 | 0.645292 | -0.3% | 1230864 | 1230824 |
| 32 | front / 5 | 0.660292 | 0.639542 | -3.1% | 1232144 | 1238544 |
| 256 | prefix / 5 | 5.801875 | 5.558417 | -4.2% | 11287824 | 11346320 |
| 256 | prefix / 100 | 4.943625 | 5.056167 | +2.3% | 9794832 | 9794792 |
| 256 | front / 5 | 5.297916 | 5.109459 | -3.6% | 9805072 | 9873808 |
| 1024 | prefix / 5 | 30.635458 | 23.700208 | -22.6% | 45128976 | 45411728 |
| 1024 | prefix / 100 | 22.376625 | 20.661000 | -7.7% | 39157008 | 39156968 |
| 1024 | front / 5 | 21.898583 | 20.537500 | -6.2% | 39197968 | 39521680 |

At 1,024 cooling-prefix rows the observed p50 is 30.635458 → 23.700208 ms (-22.6%), while allocation rises 282,752 bytes (+0.63%). The zero-row eligibility control is 0.038625 → 0.050417 ms; the 32-row cooling prefix also rises slightly. Eligible/front controls also fluctuate, so elapsed differences cannot all be attributed to membership. Whole-record validation/decoding remains a substantial cost. No priority/cohort speedup is claimed.

## Correctness and evidence binding

Both original and candidate execute `claim_next` on separate copies of each fixture: 15 exact-ID controls per executable. Cooling prefix selects the fresh `membership-N`; the exact retry boundary selects `membership-00000` when N > 0; manual-front selects the fresh request. Both sides agree in all 30 controls. Seed additionally checks that a queue containing only cooling retries is not claimable before adding fresh work. Measurements leave all ten fixture database hashes unchanged.

Four focused candidate suites pass: continuation 17, gates 12, operation store 18, semantic store 26 (**73 total**). Their preserved logs and executable hashes are in the manifest. This includes retry/deadline and gate controls, batching, manual priority/cohort, restart/commit handling, and semantic corruption checks; it is not the full regression. No timing threshold or text/layout snapshot test was added.

The final harness explicitly depends on `mtime` and `mtime.clock`. Rebuilding both executables with that declaration produced bytes identical to their measured versions; the receipt records both hashes. Earlier exploratory measurements used a narrower runner and are excluded from this evidence.

## Reproduce

Build the explicit target listed in the manifest. For the baseline, use the exact recorded base production source plus the identical candidate runner and its executable stanza. This is a fixture-level comparison, not a build of a moving main combination. With both executables copied outside their build directories:

```sh
mkdir fixtures
./baseline-bench.exe seed fixtures
./baseline-bench.exe measure fixtures
./candidate-bench.exe measure fixtures
# Repeat in candidate/baseline then baseline/candidate order.
# For each executable, control root must be a fresh copy of fixtures:
./baseline-bench.exe control copied-fixtures prefix 5
./baseline-bench.exe control another-copy prefix 100
./baseline-bench.exe control third-copy front 5
```

The runner validates all actual selected IDs. Use fresh fixture paths; seeding an existing store would replay prior admissions. Preserve the same host, fixtures, runner and commands for a fresh comparison.

Full regression and CI: not run. Latest full-regression run/head/suite list: not inspected. Candidate installation, live latency and visible UI improvement: unverified.
