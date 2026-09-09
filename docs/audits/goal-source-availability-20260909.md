# Goal source availability — reverse audit

Observed 2026-09-09 01:48 KST against live binary `cdfc6ea4c4ce29be3948fec7a71b6a7c24b05828`.

| Boundary | Observation |
| --- | --- |
| Primary and recovery files | 97 Goals each; no `criterion_revision` fields |
| Both file SHA-256 digests | `1eb311f44b01aa4b1d75ee8a05e55ad3b4fef92e70c4e2578d78c631cce1724a` |
| Live parser log | `goal_of_yojson: criterion_revision must be a non-blank string` |
| Planning and Goals HTTP APIs | Successful empty collections and zero counts |
| Actual browser Work page | `활성 목표 0`, `주의 목표 없음 · 정상 순환` |
| Live health | `overall_status: degraded` |

The failure is converted to an empty state by `Goal_store.read_state`. The source is present but unreadable by the current schema; its records have not been deleted. Recovery reads also lose their provenance before display. This change introduces a primary-only result reader for Planning, Goals tree and detail, and preserves failure through those consumers. It does not fabricate revisions, migrate or reset runtime files.

The four source conditions that must remain distinct are: unreadable primary with valid recovery, both unreadable, missing primary with existing recovery, and a new store with neither file. Only the last is a valid empty current state. Feature tests exercise actual temporary files and verify that reads do not repair them.

## Remaining consumers

This PR does not establish full Goal source parity. Further result propagation is needed for `workspace_goals.handle_goal_list`, `goal_verification_agent.collect_pending`, Keeper `active_goals_tree`, `keeper_world_observation.open_goal_ids`, and linked-Goal prompt construction. Task-to-Goal validation also uses the optional reader and must distinguish unavailable from unknown. Those paths must not be assumed fixed by display tests.

## Evidence limits

The browser bundle warned it was older than the server. The observed screenshot proves the live false-empty display, not current source UI deployment. Local audit artifacts are `/tmp/masc-reverse-final-report.json`, `/tmp/masc-reverse-final-goal-errors.jsonl`, and `/tmp/masc-reverse-final-live-work.png`. No production data was modified. Behavioral and updated browser evidence must be recorded separately from parser checks and this source audit.
