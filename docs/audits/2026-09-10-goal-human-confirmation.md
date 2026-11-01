# Goal final operator confirmation

The verifier now moves a proven Goal to `awaiting_confirmation`. Only the operator confirmation endpoint can complete it. MCP public goal transitions cannot express `confirm_completion`; supplying an actor in the HTTP body is rejected.

`GET /api/v1/goals/confirmation` returns the current criterion, durable proof and the authenticated `inspection_operator_id`. A client that intends to confirm supplies `goal_id`, `expected_base_path` and `expected_masc_root`, and requires the `x-masc-workspace-read: matched-v1` response. `POST` requires exactly `goal_id`, `criterion_revision`, `request_id`, `verification_run_id`, `expected_workspace` (with `base_path` and `masc_root`) and `expected_operator_id` from the inspected response. The server compares workspace and operator before changing the Goal. Both endpoints require the existing token-bound CanAdmin credential; the actor is resolved from that credential. This is operator credential authority, not an attestation that a physical human is using an Admin token. Giving an agent an Admin credential gives it that existing authority.

The current Goal lock covers the primary proof read, exact criterion/request/run comparison, confirmation ledger commit and Goal phase write. The confirmation retains the full verifier verdict plus original operator and confirmation time. A retry—including a different authorized operator—preserves the first confirmation attribution and emits no repeated phase event. If the process stops after the confirmation ledger write but before the Goal write, the Goal remains awaiting confirmation; retrying the same POST completes the phase without another verifier call. A restart never invents human consent. Reopen archives and resets the proof/confirmation; criterion changes require a new proof request. Drop cannot be confirmed and must first reopen.

The CLI exposes inspection and explicit confirmation:

```sh
python3 scripts/goal-confirmation.py --url http://localhost:8935 --token-file /path/operator.token --goal-id GOAL > inspected-proof.json
python3 scripts/goal-confirmation.py --url http://localhost:8935 --token-file /path/operator.token --goal-id GOAL --confirm-evidence inspected-proof.json
```

The first command saves the attested workspace and authenticated inspection operator with the proof. The second command submits that binding; a different operator or workspace, a newly edited criterion, or a new proof run is refused. The inspection operator is distinct from the original confirmation operator when another operator recovers a partially recorded confirmation. These fields are client-supplied preconditions, not a signed receipt proving that a person read the evidence. Dashboard/TUI show the waiting phase, and the dashboard preserves confirmed operator attribution. There is no agent confirmation tool.

Behavior tests cover verifier-only waiting, stale request/criterion refusal, crash-boundary retry, first-operator attribution, no duplicate event, reopen invalidation and token-bound operator versus Worker/header spoofing. Frontend proof decoder and goal helper tests passed (72 cases). OCaml validation runs in CI; no local build or live Goal mutation was performed.
