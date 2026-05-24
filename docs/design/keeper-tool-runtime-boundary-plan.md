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

3. Move Git/GitHub command semantics out of `keeper_shell_ops.ml` into
   Git/GitHub domain modules or native PR tools. The structured
   `keeper_shell op=gh` path should be a compatibility surface, not the
   center of GitHub execution.
   Started in slice 3:
   - `Keeper_shell_gh_bridge` now owns `keeper_shell op=gh`
     parsing, policy checks, repo-context binding, and
     `Keeper_sandbox_runner` dispatch.
   - `keeper_shell_ops.ml` delegates `op=gh` to the bridge instead of
     carrying GitHub command semantics inline.
   - `test_keeper_shell_gh_bridge` uses an injected mock runner to
     verify backend routing and structured backend-error preservation
     without invoking Docker or `gh`.
   Continued in slice 4:
   - `Keeper_shell_git_bridge` now owns `keeper_shell op=git_clone`
     URL validation, clone path shaping, existing-clone repair, and
     backend-neutral runner dispatch.
   - `test_keeper_shell_git_bridge` uses an injected mock runner to
     verify Docker-routed clone commands and policy rejection without
     invoking Docker or Git.

4. Collapse local-vs-Docker result shaping so command failures carry the
   same semantic fields regardless of backend. Backend-specific details
   may remain as optional evidence fields.
   Started in slice 5:
   - `Keeper_sandbox_runner` now owns the route label via
     `route_for`/`route_via`.
   - `Keeper_shell_gh_bridge` and `Keeper_shell_git_bridge` no longer
     hard-code `via=docker` while shaping compatibility output.
   - `test_keeper_sandbox_runner` pins host/backend route labels, and
     `test_keeper_shell_git_bridge` uses a local-profile mock runner to
     verify `via=host` without invoking Git or Docker.

5. Tighten boundary tests so new modules cannot reintroduce
   `shell_docker` or `shell_bash` names for sandbox-runtime concerns.

## Verification

- `test_keeper_sandbox_boundary_policy` protects source-level ownership.
- `test_keeper_sandbox_docker_route` protects existing Docker route
  behavior while names and ownership move.
- `test_keeper_sandbox_runner` uses a mock backend to verify the facade
  delegates user-shell and trusted-tool commands without invoking Docker.
- `test_keeper_shell_gh_bridge` uses a mock runner to pin `op=gh`
  compatibility behavior without invoking Docker or `gh`.
- `test_keeper_shell_git_bridge` uses a mock runner to pin
  `op=git_clone` compatibility behavior without invoking Docker or Git.
- `test_keeper_shell_git_bridge` also pins local-profile result shaping,
  so `via` is present and comes from `Keeper_sandbox_runner`.
- The boundary test now fails if PR/GitHub tool modules select the
  concrete Docker backend directly.
- The boundary test now fails if `keeper_shell_ops.ml` reabsorbs
  `op=gh` or `op=git_clone` command semantics, or if active gate
  scripts name retired `keeper_shell_docker` files.
- The boundary test now fails if gh/git compatibility bridges hard-code
  Docker route labels instead of asking `Keeper_sandbox_runner`.
