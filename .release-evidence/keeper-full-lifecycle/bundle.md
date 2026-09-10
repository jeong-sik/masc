# Keeper Full-Lifecycle Evidence

- Source SHA: `0de00c6db04021e856333aa00145fe6ee068fac7`
- Bundle ID: `64743bbb8f1e59e8eab4104403712ed1a956d00dc34d0be795a0fe7765c1581b`
- Status: **passed** (14/14)

| ID | Scenario | Status | Authority transition | User outcome | Evidence log |
|---|---|---|---|---|---|
| V01 | boot_materialize | passed | validated declarations -> complete Owner install -> listener-ready health | executable membership and invalid-config reason are inspectable | `v01-boot_materialize.log` |
| V02 | owner_serialization | passed | one Owner child claim; competing direct/autonomous request queues or rejects typed | one external-effect lane per Keeper | `v02-owner_serialization.log` |
| V03 | direct_dashboard | passed | Owner -> runtime -> common terminal pipeline -> reply | visible reply and turn_ref share the admitted turn identity | `v03-direct_dashboard.log` |
| V04 | durable_restart | passed | queue commit -> reload -> exact single claim | async request survives restart | `v04-durable_restart.log` |
| V05 | exact_ack | passed | selected source incarnation alone terminalizes | a newer incarnation is not lost | `v05-exact_ack.log` |
| V06 | pre_checkpoint_failover | passed | retryable first attempt -> next candidate -> winner checkpoint owner | one final response | `v06-pre_checkpoint_failover.log` |
| V07 | post_effect_failure | passed | effect boundary closes blind replay; terminal failure stays typed | no duplicate external effect | `v07-post_effect_failure.log` |
| V08 | checkpoint_resume | passed | winning Agent Core checkpoint or official-client session owns resume | conversation continuity without cross-owner resume | `v08-checkpoint_resume.log` |
| V09 | sandbox_tool_policy | passed | descriptor policy and sandbox boundary decide before execution | forbidden tools fail before effect | `v09-sandbox_tool_policy.log` |
| V10 | hitl_replay | passed | approval decision and effect outcome remain separate; replay is exact | decision and final delivery are correlated | `v10-hitl_replay.log` |
| V11 | completion_authority | passed | natural-language result -> evidence -> authenticated typed verdict | no false task completion | `v11-completion_authority.log` |
| V13 | config_application_boundary | passed | raw save -> per-key startup/fiber/turn application state | effective value and restart requirement are explicit | `v13-config_application_boundary.log` |
| V14 | config_typo_orphan | passed | unknown/retired key -> reject; forward schema -> warning | no silent setting no-op | `v14-config_typo_orphan.log` |
| V15 | continuous_multi_source_liveness | passed | durable outbox -> active-head release; delivery terminal -> source ACK; recovery pending/transient failure -> queue-tail defer; deterministic failure -> source quarantine | one blocked Schedule/Task/Board/Goal/Comment/Fusion source does not monopolize the Keeper | `v15-continuous_multi_source_liveness.log` |
