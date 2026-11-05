---
status: runbook
---

# Execute Runbook

This runbook documents the current operator surface for `Execute` and
adjacent structured process routing. Execute is typed-only: callers provide
exactly one of a non-empty `argv` process vector, run without a shell, or a
`command` line handed as `-c` text to the shell named in `shell`.
Pipes, redirections, `;`/`&&` sequencing and `FOO=1` prefixes are `command`
syntax; there is no object form for them.

## Scope

- Covers: `Execute`, output truncation, and Shell IR command gating.
- `Grep` owns file/content search. Execute owns typed command execution.
- Does not cover: the runtime verifier itself or the approval layer for MCP
  tools.
- Async boundary: the typed `Execute` callable surface is synchronous. There is
  no background shell lifecycle surface inside `Execute`.

## Output Limits

Host subprocess capture (`Process_eio`) keeps the first 8 MiB and the last 256 KiB
of each stream (`Common.max_process_capture_head_bytes` and
`Common.max_process_capture_tail_bytes`) and marks the elided bytes with a
truncation marker. Both limits are constants; no environment variable changes them.

## Typed Input

Direct form, one process and no shell:

```json
{ "argv": ["rg", "pattern", "lib"], "cwd": "repos/masc" }
```

Shell form, one line run by the sandbox shell:

```json
{ "command": "rg --files lib | head -20", "cwd": "repos/masc" }
```

Exactly one of `argv` and `command` is present. Shell metacharacters inside
`argv` are data: a literal `|` token is an argument, not a pipe. Write pipes,
redirections, `;`/`&&` and `FOO=1` prefixes in `command`. `shell` names which
shell runs `command` (`sh`, `bash`, `zsh`, `dash`, `ksh`; default `sh`) and is
ignored with `argv`. `cwd` is a relative path inside the path jail;
`timeout_sec` defaults to 600.

## Output Streaming

Below the tool boundary the exec layer routes `Shell_ir`. An `Execute` call
reaches it as one `Simple` command (`argv` verbatim, or `shell -c command`);
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

Verification (human contributors / Keeper lanes with a local toolchain):

```bash
scripts/dune-local.sh build lib/exec/test/test_exec_dispatch_pipeline_streaming.exe
./_build/default/lib/exec/test/test_exec_dispatch_pipeline_streaming.exe
scripts/dune-local.sh build lib/exec/test/test_exec_dispatch_stdin_streaming.exe
./_build/default/lib/exec/test/test_exec_dispatch_stdin_streaming.exe
scripts/dune-local.sh build lib/exec/test/test_exec_dispatch_docker_streaming.exe
./_build/default/lib/exec/test/test_exec_dispatch_docker_streaming.exe
```

## Async Surfaces Outside `Execute`

`Execute` is synchronous: it returns when the command ends or `timeout_sec` passes.
The public schema accepts only typed command fields: `argv`, `command`, `shell`,
`cwd`, `timeout_sec`, and `intent`. It has no `job_id`, `request_id`, `poll`, or
`cancel` field.

Asynchronous execution is provided by separate typed tool families:
- **Keeper chat operations**: `masc_keeper_delegate` and `masc_keeper_msg` submit a turn and return an `operation_id` without waiting for it; `masc_keeper_delegate_status`, `masc_keeper_delegate_list` and `masc_keeper_delegate_cancel` read or cancel it.
- **Isolated Docker jobs**: `keeper_job_start`, `keeper_job_status`, `keeper_job_result`, `keeper_job_cancel` (each job runs in an isolated container and delivers a wakeup on completion).
- **Multi-Keeper compositions**: `keeper_composition_prepare`, `keeper_composition_run`, `keeper_composition_status`, `keeper_composition_result`, `keeper_composition_cancel`.

For explicitly requested targeted verification, the `test_tool_input_validation`
suite exercises `Execute`'s accepted fields and rejects background and async
lifecycle fields. The MASC leader prepares an approved candidate and its
selection receipt using the
[selection procedure](../scripts/review/APPROVED-CI-SELECTION.md). With
`candidate_sha` set to that exact candidate and `selection.json` containing its
receipt, request the explicit suite through `leader-ci.yml` on `main`:

```bash
gh workflow run leader-ci.yml --repo jeong-sik/masc --ref main \
  -f candidate="$candidate_sha" -F selection=@selection.json \
  -f tests=true -f suites=test_tool_input_validation
```

A dispatch is a request, not a passing result. Retain the completed run URL,
exact candidate SHA and selected PR scope. A candidate result does not certify
a different head or authorize a merge.
