# Keeper Tool Runtime Boundary Plan

Last updated: 2026-05-24

## Problem

Keeper execution currently has several module names that couple tool
surfaces to runtime environments, for example shell/bash/GitHub logic
combined with Docker-specific helpers. This makes Docker vs local look
like a tool semantics choice, even though sandbox backend selection
should be orthogonal to typed command validation, Git/GitHub semantics,
and public tool aliases.

## Principles

- Public tool surfaces name user capabilities: `Bash`, `keeper_bash`,
  `keeper_shell`, PR tools, file tools.
- Sandbox modules name runtime responsibilities: backend selection,
  target construction, mounts, credentials, process execution, failure
  recording.
- Git and GitHub modules name domain semantics: repo context, `gh`
  command validation, credential binding, PR workflow.
- Docker/local selection must happen after command input is typed,
  parsed, permission-gated, and lowered to the backend-neutral execution
  request.

## Refactor Sequence

1. Decouple obvious godfile-decomp helpers from shell/docker names.
   Done in this slice:
   - `Keeper_shell_docker` -> `Keeper_sandbox_docker`
   - `Keeper_shell_docker_exec_failure` -> `Keeper_sandbox_exec_failure`
   - `Keeper_shell_bash_docker` -> `Keeper_sandbox_shell_ir_target`

2. Replace direct `Keeper_sandbox_docker` calls from tool-specific modules
   with a backend-neutral sandbox command runner facade. No legacy
   `run_docker*` compatibility aliases remain in `Keeper_shell_shared`.
   Tool modules now pass host and backend command projections to
   `Keeper_sandbox_runner.run_command_with_status`; the runner decides
   whether the command executes on the host or through the sandbox backend.

3. Remove the legacy Git/GitHub compatibility ops from `keeper_shell`.
   GitHub access now belongs to dedicated PR tools and typed command
   paths; `keeper_shell_ops.ml` no longer dispatches `op=gh` or
   `op=git_clone`, and the bridge modules/tests were deleted instead
   of kept as compatibility shims.

4. Collapse local-vs-Docker result shaping so command failures carry the
   same semantic fields regardless of backend. Backend-specific details
   may remain as optional evidence fields.
   Started in slice 5:
   - `Keeper_sandbox_runner` now owns the route label via
     `route_for`/`route_via`.
   - The removed `Keeper_shell_gh_bridge` and
     `Keeper_shell_git_bridge` shims no longer shape compatibility
     output.
   - `test_keeper_sandbox_runner` pins host/backend route labels for
     native tool and typed command execution.

5. Tighten boundary tests so new modules cannot reintroduce
   `shell_docker` or `shell_bash` names for sandbox-runtime concerns.
   Started in slice 6:
   - `Keeper_sandbox_read_runner` now hides Docker-routed read execution
     behind a backend-neutral facade.
   - `keeper_shell_ops.ml` no longer calls `Keeper_docker_read`
     directly and uses runner-owned backend route labels for read
     responses.
   - `test_keeper_sandbox_read_runner` uses an injected mock backend to
     pin the read facade without invoking Docker.
   - `test_keeper_sandbox_boundary_policy` now fails if structured shell
     read ops reselect `Keeper_docker_read` or hard-code `via=docker`.
   Continued in slice 7:
   - `keeper_fs_read` now uses `Keeper_sandbox_read_runner` instead of
     selecting `Keeper_docker_read` directly.
   - `keeper_fs_read` and `keeper_fs_edit` no longer hard-code
     `via=docker`; backend route labels come from the sandbox runner
     facades.
   - `test_keeper_sandbox_boundary_policy` now fails if file tools
     reselect `Keeper_docker_read` or hard-code `via=docker`.

## Verification

- `test_keeper_sandbox_boundary_policy` protects source-level ownership.
- `test_keeper_sandbox_docker_route` protects existing Docker route
  behavior while names and ownership move.
- `test_keeper_sandbox_runner` uses a mock backend to verify the facade
  delegates user-shell and trusted-tool commands without invoking Docker.
- The boundary test now fails if PR/GitHub tool modules select the
  concrete Docker backend directly.
- The boundary test now fails if `keeper_shell_ops.ml` reabsorbs
  `op=gh` or `op=git_clone` command semantics, or if active gate
  scripts name retired `keeper_shell_docker` files.
- The boundary test now fails if structured shell read ops call
  `Keeper_docker_read` directly instead of `Keeper_sandbox_read_runner`.
- The boundary test now fails if file tools call `Keeper_docker_read`
  directly or hard-code Docker route labels instead of asking the
  sandbox runner facades.
- `test_keeper_sandbox_read_runner` verifies facade delegation with a
  mock backend and route labels sourced from `Keeper_sandbox_runner`.
