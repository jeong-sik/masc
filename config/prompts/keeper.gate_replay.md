---
description: Gate replay/resolution model-facing wording composed per resolution state — each state arm picks its own slot
category: keeper
operator_surface: fragment
---
### resolution_consumed_without_outcome (vars: approval_id, operation)
Gate resolution delivered:
- approval_id: {{approval_id}}
- operation: {{operation}}
- state: authorization consumed, replay outcome unavailable
Do not request the operation again: its effect may already have happened. Operator repair is required.

### resolution_invalid_replay_state (vars: approval_id)
Gate resolution {{approval_id}} has an invalid durable replay state. Do not execute the external effect; operator repair is required.

### resolution_journal_unreadable (vars: approval_id)
Gate resolution {{approval_id}} could not be read from its durable journal; this event will be retried.

### resolution_absent (vars: approval_id, store)
Gate resolution {{approval_id}} has no durable record to replay ({{store}}). The approved operation was not run by this replay and this event will not be retried. If the effect is still needed, issue the call again; it will ask for approval afresh.

### resolution_rejected (vars: approval_id, rationale)
Gate resolution delivered:
- approval_id: {{approval_id}}
- decision: rejected
- rationale: {{rationale}}
This resolution grants no authorization.
If you told someone this call was parked, say it was declined and carry the conversation on from there.

### artifact_missing (vars: sha256)
replay artifact {{sha256}} is missing

### artifact_length_mismatch (vars: sha256, expected, actual)
replay artifact {{sha256}} byte length mismatch: expected={{expected}} actual={{actual}}

### approval_input_drifted (vars: operation)
approved {{operation}} no longer matches what was approved; not applied

### approval_consumption_mismatch
stored approval did not match its own exact request

### replay_outcome_missing_after_restart
authorization was consumed before restart, but no durable replay outcome exists; the effect may already have happened and will not be replayed

### replay_outcome_before_consumption
replay outcome exists before grant consumption

### replay_effect_raised (vars: detail)
approved effect raised during replay: {{detail}}
