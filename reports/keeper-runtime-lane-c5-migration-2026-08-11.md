# C5 official-client lane migration

Status: **prepared, not applied to live configuration**
Live target: `/Users/dancer/me/.masc/config/runtime.toml`
Reason for hold: this file is external operator state. Repository work does not
authorize mutating or restarting the live MASC deployment.

## Why the old single-slot restriction is stale

The live file currently leaves four official-client lanes with one candidate
and explains that an Agent Core fallback would be finalized against the lane's
official-client checkpoint owner. The code contract no longer does that:

- `Keeper_turn_driver.selected_run_result` records the checkpoint owner of the
  runtime that actually won the attempt, not the lane identifier.
- `Keeper_agent_run` forwards that selected owner to
  `Keeper_agent_run_finalize_response`.
- `Keeper_official_client_session_store.plan_claim` starts a fresh session when
  the client kind or runtime id changes, and refuses incomplete concurrent
  claims rather than inheriting a foreign session.
- `test_runtime_config_validity.ml` contains
  `test_load_allows_a_lane_that_mixes_checkpoint_owners`.
- `test_keeper_turn_driver_failover.ml` asserts that an Agent Core fallback is
  returned with `Masc_agent_core` ownership.
- `test_official_client_session_store.ml` asserts that cross-client and
  cross-runtime changes reset the turn ordinal and do not resume the previous
  settlement.

These are repository proofs. CI remains the execution authority for them.

## Proposed live change

After the required CI evidence is green, restore the previously configured
Agent Core fallback to these four lanes:

```toml
[runtime.lanes."codex_subscription.gpt-5.3-codex-spark"]
strategy = "ordered"
candidates = [
  "codex_subscription.gpt-5.3-codex-spark",
  "glm-coding.glm-5-turbo",
]

[runtime.lanes."claude_code.claude-sonnet-5"]
strategy = "ordered"
candidates = [
  "claude_code.claude-sonnet-5",
  "glm-coding.glm-5-turbo",
]

[runtime.lanes."claude_code.claude-opus-5-max"]
strategy = "ordered"
candidates = [
  "claude_code.claude-opus-5-max",
  "glm-coding.glm-5-turbo",
]

[runtime.lanes."antigravity_subscription.gemini-3-6-flash-high"]
strategy = "ordered"
candidates = [
  "antigravity_subscription.gemini-3-6-flash-high",
  "glm-coding.glm-5-turbo",
]
```

Replace the stale ownership-warning comment with a short dated note saying
that checkpoint ownership follows the selected winner and a changed
official-client runtime starts a fresh native session.

## Apply gate

Do not apply until all conditions are true:

1. CI passes the mixed-owner config validity, turn-driver failover, official
   session-store, and terminal parity suites.
2. The generated Keeper V01-V14 evidence bundle is `passed`, references the
   deployed source SHA, and verifies every scenario log digest.
3. The active runtime catalog still resolves all five candidate ids and the
   `glm-coding.glm-5-turbo` credential is healthy.
4. An operator explicitly approves editing the live file and the associated
   reload/restart boundary.

## Post-apply observations

- Resolved lane order exactly matches the four snippets above.
- A failed official-client head can select GLM without a checkpoint-owner
  finalization error.
- The winner's runtime id and checkpoint owner agree in the execution receipt.
- A later switch back to an official client starts a fresh native session; it
  does not reuse the Agent Core checkpoint or an older client's settlement.
- Queue work-liveness improves without a rise in ambiguous delivery or
  duplicate-effect counters.

## Rollback

Rollback is limited to removing the GLM second candidate from the affected
lane. Do not delete session, checkpoint, queue, or delivery-intent state as part
of this rollback; those stores have independent authority and recovery rules.
