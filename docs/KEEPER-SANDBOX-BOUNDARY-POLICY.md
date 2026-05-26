# Keeper Sandbox Boundary Policy

Last updated: 2026-05-25

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
| `Keeper_shell_op` | Structured `tool_search_files` operation vocabulary and valid op strings | Dispatch implementation, timeout policy, path resolution |
| `Keeper_shell_timeout` | Keeper shell timeout constants, user timeout clamping, typed Shell IR timeout floors | Tool dispatch, command parsing, path resolution |
| `Keeper_shell_runtime_paths` | Runtime path rewrites between container-visible and host-visible paths | Cwd/path validation, command execution, Docker lifecycle |
| `Keeper_shell_readonly_policy` | Readonly shell rejection categories, Good/Bad hints, and structured recovery diagnoses | Shell IR dispatch, cwd/path resolution, Docker runtime ownership |
| `Keeper_shell_ir` | Shell IR construction, gate/path validation, and classified dispatch facade for keeper shell surfaces | Tool request parsing, GitHub workflow semantics |
| `Keeper_shell_path` | `tool_search_files` cwd/path resolution, path autocorrect, and PATH executable probes | Shell IR dispatch, process execution, Docker runtime ownership |
| `Keeper_shell_command_parse` | Raw shell command parsing into Shell IR | Command-shape policy, Docker process execution |
| `Keeper_shell_command_words` | Dependency-light command word extraction for guard tokens, action keys, and history/logging command prefixes | Sandbox cwd policy, Docker process execution |
| `Keeper_shell_command_semantics` | Pure command-shape and cwd policy for `git`/`gh` commands | Docker process execution |
| `Keeper_sandbox_shell_ir_target` | Backend target construction for typed Shell IR dispatch | Tool-surface ownership, command parsing, `tool_execute` policy |
| `Keeper_sandbox_runner` | Backend-neutral command execution facade used by tools; route selection between host and sandbox backend; mockable backend contract | Git/GitHub workflow semantics, tool input validation, command parsing ownership |
| `Keeper_sandbox_docker` | Docker runtime setup, mounts, network mode, command execution, Docker result envelope | Generic command classification or cwd policy ownership |
| `Github_cli_executor` | Shared GitHub CLI argv execution through the sandbox runner | PR/review argument construction, GitHub command parsing |
| `Keeper_gh_repo` | GitHub repo slug validation and host-side origin discovery for GH tools | GH command parsing/risk classification, PR/review response envelopes |
| `Keeper_sandbox_exec_failure` | Sandbox backend failure messages and registry recording | Tool-surface naming, command classification, shell-specific policy |

## Deterministic Rules

- Canonical sandbox profiles are only `local` and `docker`.
- Legacy aliases are rejected, not warned and reinterpreted.
- Keeper TOML is parsed with `Otoml`, not ad hoc string parsing.
- Docker container roots are path projections from the config contract,
  not literals in tool code.
- Per-command `git`/`gh` behavior is command semantics, not a sandbox
  profile.
- Raw command parsing is centralized in `Keeper_shell_command_parse`.
  Docker, GitHub, and command-word callers must not call
  `Exec_policy.parse_string_to_ir` directly.
- Raw command word extraction is centralized in `Keeper_shell_command_words`.
  Other keeper modules must not call `Exec_policy_mutation_classifier`
  directly.
- Keeper shell cwd/path resolution and PATH executable probes are centralized
  in `Keeper_shell_path`.
- Keeper shell op vocabulary, timeout policy, and runtime path rewrites are
  centralized in `Keeper_shell_op`, `Keeper_shell_timeout`, and
  `Keeper_shell_runtime_paths`.
- Readonly shell hints and block diagnoses are centralized in
  `Keeper_shell_readonly_policy`.
- `Keeper_shell_shared` is retired; do not reintroduce it as a compatibility
  facade or implementation owner.
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

Source-level boundary tests prevent regressions in layer ownership:

- `test_keeper_sandbox_boundary_policy`
- `test_keeper_sandbox_runner`

The boundary test intentionally fails if:

- tool code reintroduces Docker path literals or profile detection;
- coord worktree helpers reintroduce Docker container-root construction
  or sandbox-profile parsing;
- Docker shell code re-exports generic command classification or parses
  raw shell commands directly;
- GitHub tool code bypasses `Github_cli_executor`;
- GitHub repo slug/origin discovery returns to `Keeper_gh_command_parse` instead
  of `Keeper_gh_repo`;
- typed Bash or structured shell ops construct Shell IR outside
  `Keeper_shell_ir`;
- `Keeper_shell_shared` source files return;
- structured shell ops or PR/GitHub tools route cwd/path resolution outside
  `Keeper_shell_path`;
- production shell modules bypass the dedicated op, timeout, runtime-path,
  readonly-policy, or path owner modules;
- keeper modules outside `Keeper_shell_command_parse` call
  `Exec_policy.parse_string_to_ir`;
- keeper modules outside `Keeper_shell_command_words` call
  `Exec_policy_mutation_classifier`;
- PR/GitHub tool code calls `Keeper_sandbox_docker` or selects Docker via
  `meta.sandbox_profile = Docker`;
- typed Shell IR backend target helpers are coupled to a `shell_bash`
  module name;
- sandbox backend failure recording is coupled to a `shell_docker`
  module name;
- legacy sandbox aliases return to runtime parsing;
- keeper TOML parsing stops using the structured parser;
- command semantics reintroduces word extraction or string-split fallback
  parsing.
