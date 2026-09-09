# Goal completion contract: source evidence

Inspected source: `90fd79462fea89e0f72dfa6d4243578538473090`.
The table audits source; the separately identified older-binary probe below covers only creation/readback, not completion or browser acceptance.

| Requirement | Current evidence | Remaining acceptance |
| --- | --- | --- |
| Quantitative condition at creation | `lib/goal/goal_store.ml`, new-row branch of `upsert_goal`, rejects missing/blank metric or target inside the store lock. Optional record fields do not establish an optional creation contract. | Exercise actual API create/readback in the candidate runtime. |
| Verifier checks feasibility of the proposed criterion | `handle_goal_upsert` directly calls `Goal_store.upsert_goal`. The existing verifier asks whether the metric reached its target (`goal_verification_agent.ml`, proof review). | Creation feasibility evaluation and observable result remain separate from completion proof. |
| Verifier proves completion | `Goal_phase` transitions Executing → Verifying on Request_complete. `commit_verifier_decision` persists a criterion/request/run-bound verdict; reconciliation can recover it. | Real evaluator evidence against the declared metric, including deferred/refuted paths. |
| Human finally confirms | Verifying + Record_proof_proven moves directly to Completed. `commit_verifier_decision`, `reconcile_committed_proof`, and `answer_verifying_repeat` share that transition. | Durable pending confirmation, authenticated review of the exact proof, explicit final decision, and restart/readback/browser proof. |

Existing Task operator routes use `Server_auth.with_token_permission_auth` with `CanAdmin`. The helper requires enabled token authentication, resolves the stored credential, checks its role, and supplies the credential identity. It does not establish that a human rather than software possesses that credential. Caller-provided actor strings must not become confirmation authority.

The constitution annotations are corrected to describe this inspected implementation while retaining the original product requirements. No product behavior changes in this audit.

## Isolated creation/readback probe

On 2026-09-09 at 22:10 UTC, the existing c083 candidate on loopback port 18937 accepted the PDF quality Goal with metric and target, rejected a second Goal lacking target, and returned only the accepted Goal with its original criterion revision. Raw MCP receipts and checked hashes are in `docs/evidence/2026-09-10-goal-create-readback/`. This is not an exact-main or production proof, not a feasibility judgment, and not completion verification. The accepted Goal remains executing for the actual PDF work.
