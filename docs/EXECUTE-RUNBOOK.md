---
status: runbook
last_verified: 2026-06-11
code_refs:
  - lib/exec/exec_buffer.ml
  - lib/exec_core.ml
  - lib/exec/exec_dispatch.ml
  - lib/exec/exec_gate.ml
  - lib/process/process_eio.ml
  - lib/exec/command_gate/shell_command_gate.ml
  - lib/exec_policy/exec_policy.ml
  - lib/keeper/keeper_tool_command_runtime.ml
---

# Execute Runbook

This runbook documents the current operator surface for `Execute` and
adjacent structured process routing. Execute is typed-only: callers provide
one non-empty `argv` process vector or `pipeline`. Raw command strings and the old
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

## Typed Input

Single process:

```json
{ "argv": ["rg", "pattern", "lib"], "cwd": "repos/masc" }
```

Pipeline:

```json
{
  "pipeline": [
    { "argv": ["rg", "--files", "lib"] },
    { "argv": ["head", "-20"] }
  ],
  "cwd": "repos/masc"
}
```

Shell metacharacters inside `argv` are data. Use `pipeline` for pipes
instead of embedding `|` in a string. For read-only observation prefer
`Grep`; for file edits use `Edit`/`Write`.

## Output Streaming

The host native pipeline, host simple typed-stdin, and Docker runner contract
routes forward `on_output_chunk` while the process is still running. The
concrete host routes are:

```text
Exec_dispatch.dispatch_pipeline
  -> Exec_gate.run_argv_pipeline_with_status_split
  -> Process_eio.run_argv_pipeline_with_status_split

Exec_dispatch.dispatch_simple ~stdin_content
  -> Exec_gate.run_argv_with_stdin_and_status_split
  -> Process_eio.run_argv_with_stdin_and_status_split
```

Pipeline callbacks are emitted from the final stdout pipe and each stage's
stderr pipe as chunks are read. Intermediate stdout remains process-to-process
pipe data and is not surfaced as user output. Simple host typed-stdin callbacks
are emitted from that command's stdout/stderr pipes as chunks are read.

Docker Shell IR targets receive the same stdout/stderr callback contract through
`Sandbox_target.runner` and `Sandbox_target.pipeline_runner`; the keeper Docker
adapter forwards those callbacks to the underlying `docker exec` process drain.
When a pipeline falls back to decomposed stage execution, stage stderr is
streamed as each stage runs and only the final stage's stdout is surfaced as
user output; intermediate stdout remains stdin for the next stage.

Verification:

```bash
scripts/dune-local.sh build lib/exec/test/test_exec_dispatch_pipeline_streaming.exe
./_build/default/lib/exec/test/test_exec_dispatch_pipeline_streaming.exe
scripts/dune-local.sh build lib/exec/test/test_exec_dispatch_stdin_streaming.exe
./_build/default/lib/exec/test/test_exec_dispatch_stdin_streaming.exe
scripts/dune-local.sh build lib/exec/test/test_exec_dispatch_docker_streaming.exe
./_build/default/lib/exec/test/test_exec_dispatch_docker_streaming.exe
```

## Async Boundary Proof

`Execute` remains synchronous at the callable-surface level. The public schema
rejects legacy background flags and accepts only typed command fields:
`executable`, `argv`, `pipeline`, `env`, `cwd`, `timeout_sec`, `stdin`,
`stdout`, and `stderr`. It does not expose `job_id`, `request_id`, `poll`, or
`cancel` fields.

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
