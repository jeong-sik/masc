# Main Goal registration after the isolated experiment

These are actual API receipts for main8935, not the isolated GLM canary. The unchanged criterion is `306708facbfb9379a9e51b8f7c815678` for `goal-outcome-driven-work-20261024`.

| UTC, 2026-10-25 | Recorded outcome | Original receipt |
| --- | --- | --- |
| 00:41:14 | Measurement `ff5d3c4d17dd26b6393a97b4d942e201`, reported-only11/11 within each case's explicit scope | [Measurement](measurement11/receipt.json) |
| 00:44:50 | Task2620 submitted as `vrf-6267bb77e2da35dc33f8991eddf2a446`, capture diagnostics empty | [Submission](task2620-submission/receipt.json) |
| 00:45:12 | Main Goal request `b0792fb9b86e66445ccd673bc6463ce2` accepted: Verifying/proof_pending | [Goal request](goal-proof-request/receipt.json) |
| 01:01:45 | Those states retained in sequential primary-file reads | [Selected primary records](primary-state-010145.json) |
| 01:10:38 | One read-only health check: connection refused | [Health observation](health-read-011038.json) |
| 01:10:46 | Goal still Verifying/proof_pending; measurement ID unchanged | [Later primary records](primary-state-011046.json) |
| 01:22:44 | Main Goal still proof_pending, Task2620 AwaitingVerification; canonical acceptance hash unchanged | [Final sequential primary records](final-primary-state.json) |

The measurement binds the canonical experiment-owned acceptance file SHA256 `4fdd1ec82f3953be507615397ecbffd170dea0ff5df5476cd28222f22302905e`, frozen at2026-10-24T18:31:26Z. That snapshot's pending main-registration bookkeeping describes its write time. It was not rewritten after registration. The prior registered9/11 and read timeouts remain in the [GLM evidence](../2026-10-25-goal-continuation-glm/README.md).

The installed main API returned `verification: reported_only`; it did not demonstrate installation of the newer measurement receipt implementation. The Goal request accepted no Board/Fusion submitted-evidence snapshots (`submitted_evidence: []`). Notes link public frozen evidence. Request acceptance is not independent proof. Neither the Task nor Goal was self-approved, and human Goal confirmation is absent. Primary-file observations are sequential, not atomic across stores and not proof of API availability. This session did not restart or install the main service.

The Task submission described native run40147287888 as in progress at its last read. That run subsequently finished247PASS/4FAIL. The narrow frozen-code follow-up40149490208 later passed239 tests across the three changed suites. The [failed run and actual follow-up](../2026-10-25-native-verification-followup/README.md) correct the current ledger without altering the original receipt or resubmitting solely to change prose.

The positive G2/G3 evidence is one source328 GLM-5.3 cohort. Its remaining artifact edits followed the1/3 measurement, but next-Task creation preceded that measurement. The [full sequence qualification](../2026-10-25-goal-continuation-glm/README.md) and historical negative cohorts remain material. Eleven scoped cases are not whole-regression, population reliability, installation or Goal completion.
