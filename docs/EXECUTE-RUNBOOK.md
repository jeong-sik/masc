---
status: runbook
last_verified: 2026-06-11
code_refs:
  - lib/exec/exec_semantic.ml
  - lib/exec/exec_buffer.ml
  - lib/exec_core.ml
  - lib/exec/exec_dispatch.ml
  - lib/process/process_eio.ml
  - lib/exec/command_gate/shell_command_gate.ml
  - lib/exec_policy/exec_policy.ml
  - lib/keeper/keeper_tool_command_runtime.ml
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
- `Grep` owns file/content search. Execute owns typed command execution.
- Does not cover: the runtime verifier itself or the approval layer for MCP
  tools.
- Async boundary: background shell lifecycle primitives live in `Bg_task`;
  they are not exposed through the typed `Execute` callable surface.

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
{ "executable": "rg", "argv": ["pattern", "lib"], "cwd": "repos/masc" }
```

Pipeline:

```json
{
  "pipeline": [
    { "executable": "rg", "argv": ["--files", "lib"] },
    { "executable": "head", "argv": ["-20"] }
  ],
  "cwd": "repos/masc"
}
```

Shell metacharacters inside `argv` are data. Use `pipeline` for pipes
instead of embedding `|` in a string. For read-only observation prefer
`Grep`; for file edits use `Edit`/`Write`.

## Output Streaming

The host native pipeline route forwards `on_output_chunk` while the pipeline is
still running. The concrete route is:

```text
Exec_dispatch.dispatch_pipeline
  -> Exec_gate.run_argv_pipeline_with_status_split
  -> Process_eio.run_argv_pipeline_with_status_split
```

Callbacks are emitted from the final stdout pipe and each stage's stderr pipe as
chunks are read. Intermediate stdout remains process-to-process pipe data and is
not surfaced as user output.

Docker pipeline execution and decomposed fallback paths still emit captured
output after completion. Simple host commands with typed `stdin` also still use
the completion-captured fallback path.

Verification:

```bash
scripts/dune-local.sh build lib/exec/test/test_exec_dispatch_pipeline_streaming.exe
./_build/default/lib/exec/test/test_exec_dispatch_pipeline_streaming.exe
```

## Async Boundary Proof

`Execute` remains synchronous at the callable-surface level. The public schema
rejects legacy background flags and accepts only typed command fields:
`executable`, `argv`, `pipeline`, `env`, `cwd`, `timeout_sec`, `stdin`,
`stdout`, and `stderr`.

Background shell lifecycle support exists below that boundary in `Bg_task`
(`spawn` / `read` / `kill` / `list`). Keeper-turn async messaging is a separate
surface (`keeper_msg`, `keeper_msg_result`, `keeper_msg_cancel`,
`keeper_msg_list`) and is serialized through `Keeper_turn_admission`.

Verification:

```bash
bash scripts/check-execute-async-surface.sh
```

## Counter Endpoint

```text
GET /api/v1/legendary_bash/counters
```

The payload contains only live observer families:

- `credential_exit_*` / `credential_signaled_*` / `credential_stopped_*`
- `shell_gate_*`
