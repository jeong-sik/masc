---
status: runbook
last_verified: 2026-05-21
code_refs:
  - lib/exec/exec_semantic.ml
  - lib/exec/exec_buffer.ml
  - lib/exec_core.ml
  - lib/cdal/cdal_judge.ml
  - lib/exec/command_gate/shell_command_gate.ml
  - lib/worker_dev_tools.ml
  - lib/keeper/agent_tool_command_runtime.ml
---

# Execute Runbook

This runbook documents the current operator surface for `Execute` and
adjacent structured shell routing. Execute is typed-only: callers provide
`executable`/`argv` or `pipeline`. Raw command strings and the old
background task lifecycle are not part of the callable surface.

## Related Documents

- [`ENV-CONTRACT.md`](./ENV-CONTRACT.md) §4 — authoritative flag matrix
- [`BOOT-ENV-STATE-INVENTORY.md`](./BOOT-ENV-STATE-INVENTORY.md)
- `planning/graceful-panda/Legendary-Execute-plan.md` — historical source plan

## Scope

- Covers: `Execute`, typed semantic exit, output truncation, Shell IR command
  gating, verification contract markers, and shell-gate counters.
- `SearchFiles` owns file/content search. Execute owns typed command execution.
- Does not cover: the cascade verifier itself or the approval layer for MCP
  tools.

## Current Rollout State

| Phase | Feature | Default | Status |
| --- | --- | --- | --- |
| P1 | `semantic_exit` typed return code | **on** | flipped |
| P3 | head+tail truncation | on | delivered |
| P5 | Shell IR command gate | on | authoritative |
| P6 | `verifiable_markers` emission | **on** | flipped |

## Flag Matrix

| Variable | Default | Opt-out tokens | What changes |
| --- | --- | --- | --- |
| `MASC_BASH_SEMANTIC_EXIT` | on | `0`, `false`, `no`, `off` | drops `return_code_interpretation` JSON field |
| `MASC_BASH_OUTPUT_CAP` | on | none | head+tail truncation; `MASC_BASH_CAP_HEAD` / `MASC_BASH_CAP_TAIL` override per-stream caps |
| `MASC_BASH_VERIFIABLE_MARKERS` | on | `0`, `false`, `no`, `off` | drops typed `verifiable_markers` from `Cdal_judge` |

## Typed Input

Single process:

```json
{ "executable": "rg", "argv": ["pattern", "lib"], "cwd": "repos/masc-mcp" }
```

Pipeline:

```json
{
  "pipeline": [
    { "executable": "rg", "argv": ["--files", "lib"] },
    { "executable": "head", "argv": ["-20"] }
  ],
  "cwd": "repos/masc-mcp"
}
```

Shell metacharacters inside `argv` are data. Use `pipeline` for pipes
instead of embedding `|` in a string. For read-only observation prefer
`SearchFiles`; for file edits use `EditFile`/`WriteFile`.

## Counter Endpoint

```text
GET /api/v1/legendary_bash/counters
```

The payload contains only live observer families:

- `repo_cli_exit_*` / `repo_cli_signaled_*` / `repo_cli_stopped_*`
- `shell_gate_*`
