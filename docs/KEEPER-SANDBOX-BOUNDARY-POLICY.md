# Keeper Sandbox Boundary Policy

Last updated: 2026-05-21

## Goal

Keeper execution must keep deterministic configuration, tool request
validation, Docker execution, and command-shape semantics in separate
layers. A tool failure such as a nonexistent file path must stay a tool
or model-context failure; it must not be reclassified as a Docker
failure just because a keeper uses the Docker backend.

## Layer Contract

| Layer | Owns | Must not own |
| --- | --- | --- |
| `Keeper_sandbox_config` | Structured keeper TOML parsing, canonical sandbox profile validation, backend storage-root projection, sandbox-visible path projection | Tool execution, shell command dispatch, Docker process lifecycle |
| `Keeper_sandbox` | Keeper-facing sandbox contract used by tools and status surfaces | Manual TOML parsing, Docker launch policy |
| `Coord_worktree_paths` | Worktree shape checks and path consumers | Sandbox-profile parsing, Docker container-root construction |
| `Tool_code` / write tools | Tool input validation and sandbox-visible path normalization via `Keeper_sandbox` | Docker prefix literals, profile detection, keeper TOML reads |
| `Keeper_shell_command_semantics` | Pure command-shape and cwd policy for `git`/`gh` commands | Docker process execution |
| `Keeper_sandbox_shell_ir_target` | Backend target construction for typed Shell IR dispatch | Tool-surface ownership, command parsing, `keeper_bash` policy |
| `Keeper_sandbox_runner` | Backend-neutral command execution facade used by tools; route selection between host and sandbox backend; mockable backend contract | Git/GitHub workflow semantics, tool input validation, command parsing ownership |
| `Keeper_sandbox_docker` | Docker runtime setup, mounts, network mode, command execution, Docker result envelope | Generic command classification or cwd policy ownership |
| `Keeper_sandbox_exec_failure` | Sandbox backend failure messages and registry recording | Tool-surface naming, command classification, shell-specific policy |

## Deterministic Rules

- Canonical sandbox profiles are only `local` and `docker`.
- Legacy aliases are rejected, not warned and reinterpreted.
- Keeper TOML is parsed with `Otoml`, not ad hoc string parsing.
- Docker container roots are path projections from the config contract,
  not literals in tool code.
- Per-command `git`/`gh` behavior is command semantics, not a sandbox
  profile.
- Tool modules must not branch on `meta.sandbox_profile = Docker` or call
  `Keeper_sandbox_docker` directly. They pass host/backend command
  projections to `Keeper_sandbox_runner`.
- Command semantics may only interpret commands accepted by the typed
  bash subset parser. Unsupported shell constructs fail closed and must
  not be reinterpreted with space splitting or fallback token scans.

## Verification Policy

Focused behavioral tests verify path and command behavior:

- `test_keeper_path_ssot`
- `test_keeper_sandbox_docker_route`
- `test_gh_exit_class_wiring`

Source-level boundary tests prevent regressions in layer ownership:

- `test_keeper_sandbox_boundary_policy`
- `test_keeper_sandbox_runner`

The boundary test intentionally fails if:

- tool code reintroduces Docker path literals or profile detection;
- coord worktree helpers reintroduce Docker container-root construction
  or sandbox-profile parsing;
- Docker shell code re-exports generic command classification;
- PR/GitHub tool code calls `Keeper_sandbox_docker` or selects Docker via
  `meta.sandbox_profile = Docker`;
- typed Shell IR backend target helpers are coupled to a `shell_bash`
  module name;
- sandbox backend failure recording is coupled to a `shell_docker`
  module name;
- legacy sandbox aliases return to runtime parsing;
- keeper TOML parsing stops using the structured parser;
- command semantics reintroduces string-split fallback parsing.
