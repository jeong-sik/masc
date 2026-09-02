---
status: runbook
---

# Execute Runbook

This runbook documents the current operator surface for `Execute` and
adjacent structured process routing. Execute is typed-only: callers provide
exactly one of a non-empty `argv` process vector, run without a shell, or a
`script` command line handed as `-c` text to the shell named in `shell`.
Pipes, redirections, `;`/`&&` sequencing and `FOO=1` prefixes are `script`
syntax; there is no object form for them. Raw `cmd` strings and the old
background task lifecycle are not part of the callable surface.

## Related Documents

- [`ENV-CONTRACT.md`](./ENV-CONTRACT.md) §4 — authoritative flag matrix
- `planning/graceful-panda/Legendary-Execute-plan.md` — historical source plan

## Scope

- Covers: `Execute`, typed semantic exit, output truncation, Shell IR command
  gating, verification contract markers, and shell-gate counters.
- `Grep` owns file/content search. Execute owns typed command execution.
- Does not cover: the runtime verifier itself or the approval layer for MCP
  tools.
- Async boundary: the typed `Execute` callable surface is synchronous. There is
  no background shell lifecycle surface anywhere below it.

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

Direct form, one process and no shell:

```json
{ "argv": ["rg", "pattern", "lib"], "cwd": "repos/masc" }
```

Shell form, one line run by the sandbox shell:

```json
{ "script": "rg --files lib | head -20", "cwd": "repos/masc" }
```

Exactly one of `argv` and `script` is present. Shell metacharacters inside
`argv` are data: a literal `|` token is an argument, not a pipe. Write pipes,
redirections, `;`/`&&` and `FOO=1` prefixes in `script`. `shell` names which
shell runs `script` (`sh`, `bash`, `zsh`, `dash`, `ksh`; default `sh`) and is
ignored with `argv`. `cwd` is a relative path inside the path jail;
`timeout_sec` defaults to 600.

## Output Streaming

Below the tool boundary the exec layer routes `Shell_ir`. An `Execute` call
reaches it as one `Simple` command (`argv` verbatim, or `shell -c script`);
the `Pipeline` and stdin-content routes are reached by callers that build
`Shell_ir` directly, not by any typed `Execute` field. The host pipeline, host
simple-with-stdin, and Docker runner contract routes forward
`on_output_chunk` while the process is still running. The concrete host
routes are:

```text
Exec_dispatch.dispatch_pipeline
  -> Process_eio.run_argv_pipeline_with_status_split

Exec_dispatch.dispatch_simple ~stdin_content
  -> Process_eio.run_argv_with_stdin_and_status_split
```

Pipeline callbacks are emitted from the final stdout pipe and each stage's
stderr pipe as chunks are read. Intermediate stdout remains process-to-process
pipe data and is not surfaced as user output. Simple host stdin-content callbacks
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
`argv`, `script`, `shell`, `cwd`, and `timeout_sec`. It does not expose
`job_id`, `request_id`, `poll`, or `cancel` fields.

Keeper-turn async messaging is a separate surface (`keeper_msg`,
`keeper_msg_result`, `keeper_msg_cancel`, `keeper_msg_list`) and is serialized
through `Keeper_turn_admission`.

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
