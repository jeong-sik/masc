---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/handover_eio.ml
---

# Context Handoff Pattern

**Legacy name**: Cellular Agent Pattern
**Status**: Implemented
**Primary modules**: `lib/handover_eio.ml`, `lib/tool_handover.ml`

## Terminology Note

This project historically used `cellular`, `DNA`, and similar biology-heavy terms for handoff flow. New documentation should prefer:

- `handoff` for context transfer
- `capsule` or `handoff record` for the transferred summary

Older code paths and documents may still use the legacy terms.

## Overview

The handoff pattern lets one agent stop work and leave a structured record for another agent to continue from. The record is durable, human-readable, and tool-addressable.

Use this pattern when:

- context usage is getting high
- the current agent is timing out or stopping
- ownership needs to move to another runtime or model
- a task should resume later without losing decisions and file context

## Handoff Record

Representative fields in a handoff record:

```ocaml
type handover_record = {
  id: string;
  from_agent: string;
  to_agent: string option;
  task_id: string;
  session_id: string;
  current_goal: string;
  progress_summary: string;
  completed_steps: string list;
  pending_steps: string list;
  key_decisions: string list;
  assumptions: string list;
  warnings: string list;
  unresolved_errors: string list;
  modified_files: string list;
  locked_files: string list;
  created_at: float;
  context_usage_percent: int;
  handover_reason: string;
}
```

The record is meant to preserve execution context, not to reproduce the full original conversation.

## Trigger Reasons

| Reason | Description | Example |
|--------|-------------|---------|
| `ContextLimit(pct)` | context usage crossed a threshold | `context_limit_85` |
| `Timeout(secs)` | runtime budget exhausted | `timeout_300s` |
| `Explicit` | user or agent requested handoff | `explicit` |
| `FatalError(msg)` | unrecoverable local failure | `error: API rate limit` |
| `TaskComplete` | work finished and a checkpoint is still useful | `task_complete` |

## MCP Tools

### `masc_handover_create`

Create a handoff record from the current task state.

```json
{
  "task_id": "task-001",
  "session_id": "session-xyz",
  "reason": "context_limit",
  "context_pct": 85,
  "goal": "PK-32008 LocalStorage SSR 버그 수정",
  "progress": "원인 파악 완료",
  "completed": ["버그 재현", "원인 분석"],
  "pending": ["수정", "테스트", "PR"],
  "decisions": ["SSR-safe 패턴 사용"],
  "assumptions": ["Next.js 14 환경"],
  "warnings": ["hydration mismatch 주의"],
  "errors": [],
  "files": ["src/hooks/useLocalStorage.ts"]
}
```

### `masc_handover_list`

List handoffs, optionally filtering to unclaimed ones.

```json
{
  "pending_only": true
}
```

### `masc_handover_claim`

Claim a handoff so another agent does not resume the same work in parallel.

```json
{
  "handover_id": "handover-abc123",
  "agent_name": "gemini"
}
```

### `masc_handover_get`

Read a handoff in markdown form for human inspection or prompt injection.

```json
{
  "handover_id": "handover-abc123"
}
```

### `masc_handover_claim_and_spawn`

Claim a handoff and start the successor runtime in one step.

```json
{
  "handover_id": "handover-abc123",
  "agent_name": "gemini",
  "additional_instructions": "Prioritize security",
  "timeout_seconds": 600
}
```

## Typical Flow

1. Source agent creates a handoff with its current goal, completed steps, warnings, and touched files.
2. Successor agent lists or claims an available handoff.
3. Successor reads the handoff markdown and resumes from `pending_steps`.
4. If the successor also needs to stop, it creates another handoff or marks the task complete.

## Storage

Handoffs are stored under:

```text
.masc/handovers/
  handover-*.json
  pending.json
```

This path comes from `lib/handover_eio.ml`.

## Design Notes

- JSON is used for persistence because it is easy to inspect and script against.
- Markdown output is used because it is readable to both humans and models.
- Explicit claim exists to avoid duplicate resume work.

## Related

- `docs/KEEPER-USER-MANUAL.md` - current keeper handoff and continuity flow
- `docs/INTERRUPT-DESIGN.md` - approval and pause patterns
- `docs/GLOSSARY.md` - preferred terminology
