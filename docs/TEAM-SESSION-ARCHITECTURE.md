# Team Session Architecture

This document describes the team-session orchestration model implemented in `masc-mcp`.

Note:
- Current canonical write path is `masc_team_session_step`.
- Older notes may mention `masc_team_session_turn`, but that alias is no longer part of the current tool inventory.

## Goal

Enable verifiable multi-agent collaboration sessions where spawned agents can:

- run multi-turn interactions,
- communicate via portal/A2A,
- leave audit/report artifacts,
- and produce machine-checkable proof output.

## Core APIs

- `masc_team_session_start`
- `masc_team_session_step`
- `masc_team_session_status`
- `masc_team_session_finalize`
- `masc_team_session_report`
- `masc_team_session_prove`
- `masc_team_session_events`
- `masc_team_session_list`
- `masc_team_session_compare`

## Session Storage

Per session under `.masc/team-sessions/<session_id>/`:

- `session.json`
- `events.jsonl`
- `checkpoints/*.json`
- `report.md`, `report.json`
- `proof.md`, `proof.json`

## Orchestration Model

1. `start`: creates session state and runtime loop.
2. `step`: canonical write entrypoint for one orchestration turn.
   - Optional worker execution (`spawn_prompt`, `worker_class`, `worker_size`, or `spawn_batch`).
   - Optional vote evidence (`vote_topic`, `vote_options`, `vote_choice`).
   - Optional run evidence (`run_task_id`, `run_note`, `run_deliverable`).
3. `finalize`: requests stop, waits terminal state, generates report/proof.
4. `prove`: emits formal proof artifacts with selectable proof level.

## Proof Levels

- `standard`: baseline traceability checks.
- `strong`: strict evidence checks for spawned multi-agent team play.

Strong proof uses additional criteria such as:

- spawned-agent evidence and diversity,
- communication volume threshold,
- vote evidence,
- deliverable evidence.

## Local-First Configuration

Recommended runtime policy:

- local-first model path (for example `llama.cpp` OpenAI-compatible endpoint),
- conditional fallback to cloud models when local execution fails or times out.

`fallback_policy=local_first_conditional` maps to session fallback handling with controlled degradation.
