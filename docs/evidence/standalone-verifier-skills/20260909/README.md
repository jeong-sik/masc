# First isolated real-model measurement

On 2026-09-09 KST, the installed binary at source commit
`05cf7d67be8ae46d2bde0c257a6af6be12404008` ran the committed acceptance runner
in its own temporary workspace. Runtime configuration and model overlay were
copied from the deployment; no production Goal or Task was submitted. All three
reviews used `glm-coding.glm-5.3-flash`. Binary and config hashes are in the receipts.

| Case | Committed verdict | Skill body read | Fixture result | Strict order |
| --- | --- | --- | --- | --- |
| matching | APPROVE | completed | full matching JSON | pass |
| wrong-revision | REJECT | completed | full JSON with wrong SHA | pass |
| missing | REJECT | completed | confirmed missing file | fail |

**Expected verdicts: 3/3. Original strict workflow acceptance: 2/3; overall false.**
For missing evidence, the read finished 0.425 ms before the Skill read. Both were
requested in the same tool batch. The observed behavior made both results
available before the verdict, but does not prove the model consumed the Skill
before selecting the lookup. The order requirement has not been relaxed.

Files:

- `original-receipt.json`: original runner output, including committed Goals and
  exact run tool observations. It remains unchanged with `passed: false`.
- `reassessed-receipt.json`: offline recheck of those same observations with the
  strengthened complete-content checker. It also remains false. This is not
  another model run.
- `*-fixture.json`: submitted evidence and required revision, used to reconstruct
  exact serialized fixture bytes for the offline recheck.
- `model-tool-log.txt`: model/tool and verifier log excerpt. The complete local
  run artifacts are `/tmp/masc-verifier-skill-proof-20260909-01`.

The full log was inspected and showed no verifier slot failures or runtime
failover during these three cases. The receipt has no per-tool attempt identity;
it cannot establish that property by itself. This is a single three-fixture Goal
probe through the shared reviewer, not Task submission, every standalone role,
production behavior, or evidence that Skill use improves model quality.

## Follow-up repairs

The merged PR's [CI run 34242007235](https://github.com/jeong-sik/masc/actions/runs/34242007235)
was green, but its nonblocking edited-suite step failed four standalone Skill
cases: declared name `evidence-guide` did not match package directory `guide`,
so the real parser rejected the fixtures. The fixture now uses `evidence-guide`
and reports catalog rejection diagnostics. No catalog validation was weakened.

Adversarial review also reproduced false acceptance for partial/empty reads.
The runner now requires an untruncated successful response containing the exact
fixture path and entire pre-recorded content. Twelve receipt-checker tests pass
locally, including partial, empty, malformed, foreign-path and truncated outputs.
These are checker tests, not additional model measurements. Corrected OCaml
behavior tests are submitted to CI; no local Dune build was run.
