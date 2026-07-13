# Keeper Sandbox Boundary Policy

Last updated: 2026-07-13

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
| `Workspace_worktree_paths` | Worktree shape checks and path consumers | Sandbox-profile parsing, Docker container-root construction |
| `Retired_file_tool` / write tools | Tool input validation and sandbox-visible path normalization via `Keeper_sandbox` | Docker prefix literals, profile detection, keeper TOML reads |
| `Keeper_workspace_op` | Structured `tool_search_files` operation vocabulary and valid op strings | Dispatch implementation, timeout policy, path resolution |
| `Agent_tool_execute_timeout` | Execute timeout constants, user timeout clamping, typed Shell IR timeout floors | Tool dispatch, command parsing, path resolution |
| `Agent_tool_execute_runtime_paths` | Runtime path rewrites between container-visible and host-visible paths | Cwd/path validation, command execution, Docker lifecycle |
| `Keeper_tool_execute_shell_ir` | Shell IR construction, gate/path validation, and classified dispatch facade for Execute/SearchFiles surfaces | Tool request parsing, remote workflow semantics |
| `Agent_tool_execute_path` | `tool_search_files` cwd/path resolution, path autocorrect, and PATH executable probes | Shell IR dispatch, process execution, Docker runtime ownership |
| `Agent_tool_execute_command_parse` | Raw shell command parsing into Shell IR | Command-shape policy, Docker process execution |
| `Agent_tool_execute_command_words` | Dependency-light command word extraction for guard tokens, action keys, and history/logging command prefixes | Sandbox cwd policy, Docker process execution |
| `Agent_tool_execute_command_semantics` | Pure command-shape and cwd policy for `git`/`gh` commands | Docker process execution |
| `Keeper_sandbox_shell_ir_target` | Backend target construction for typed Shell IR dispatch | Tool-surface ownership, command parsing, `tool_execute` policy |
| `Keeper_sandbox_runner` | Backend-neutral command execution facade used by tools; route selection between host and sandbox backend; mockable backend contract | Git/remote workflow semantics, tool input validation, command parsing ownership |
| `Keeper_sandbox_docker` | Docker runtime setup, mounts, network mode, command execution, Docker result envelope | Generic command classification or cwd policy ownership |
| `Keeper_sandbox_exec_failure` | Sandbox backend failure messages and registry recording | Tool-surface naming, command classification, shell-specific policy |

## Deterministic Rules

- Canonical sandbox profiles are only `local` and `docker`.
- Legacy aliases are rejected, not warned and reinterpreted.
- Keeper TOML is parsed with `Otoml`, not ad hoc string parsing.
- Docker container roots are path projections from the config contract,
  not literals in tool code.
- Docker subprocess status, stdout, and stderr are surfaced from one execution.
  Rendered error text must not trigger retries or output suppression; typed
  Unix I/O errors are handled only at the process boundary.
- Per-command `git`/`gh` behavior is command semantics, not a sandbox
  profile.
- Raw command parsing is centralized in `Agent_tool_execute_command_parse`.
  Docker, GitHub, and command-word callers must not call
  `Exec_policy.parse_string_to_ir` directly.
- Raw command word extraction is centralized in `Agent_tool_execute_command_words`.
  Other keeper modules must not call `Exec_policy_mutation_classifier`
  directly.
- Execute cwd/path resolution and PATH executable probes are centralized
  in `Agent_tool_execute_path`.
- SearchFiles op vocabulary, Execute timeout policy, and runtime path rewrites are
  centralized in `Keeper_workspace_op`, `Agent_tool_execute_timeout`, and
  `Agent_tool_execute_runtime_paths`.
- `shared shell compatibility facade` is retired; do not reintroduce it as a compatibility
  facade or implementation owner.
- Tool modules must not branch on `meta.sandbox_profile = Docker` or call
  `Keeper_sandbox_docker` directly. They pass host/backend command
  projections to `Keeper_sandbox_runner`.
- Status, list, operator, and sandbox-status surfaces must read effective
  keeper meta via `Keeper_meta_store.read_effective_meta*`, not raw persisted
  JSON, before displaying `sandbox_profile`, `network_mode`, `tool_access`, or
  sandbox live state. Persisted runtime JSON intentionally omits TOML-owned
  fields; raw reads can otherwise report `local` while receipts and tool
  execution correctly use `docker`.
- Runtime/provider attribution for status surfaces must come from explicit
  runtime observations and execution receipts. `Runtime_agent.run` must attach
  terminal runtime observation to completed or partial-completed turns, receipts
  must serialize `runtime.selected_model`, and runtime-trust status may fall
  back from decision telemetry to the latest receipt model. Public dashboards
  may keep provider/model lanes redacted, but keeper operator surfaces must show
  either observed attribution or a typed runtime/provider blocker. The
  `model_observability` status block must reuse the same runtime-trust /
  receipt fallback; it must not report `selected_model=null` when
  `runtime_trust.selected_model` or
  `runtime_trust.execution.provider_selected_model` is present.
- Telemetry coverage gaps are historical evidence, not permanent health
  latches. Dashboard source health may report `coverage_gap` only for active
  gaps: a gap is active until the same source has a durable row with a timestamp
  equal to or newer than the gap timestamp. Summary payloads must keep
  historical `coverage_gap_count` visible and expose
  `active_coverage_gap_count` for current health decisions.
- Command semantics may only interpret commands accepted by the typed
  bash subset parser. Unsupported shell constructs fail closed and must
  not be reinterpreted with space splitting or fallback token scans.

## Verification Policy

Focused behavioral tests verify path and command behavior:

- `test_keeper_path_ssot`
- `test_keeper_effective_meta_overlay`
- `test_keeper_runtime_trust_snapshot`
- `test_runtime_provider_auth_headers`
- `test_telemetry_unified` recovered coverage-gap summary test
- `test_keeper_tool_call_log` recovered tool-call coverage-gap aggregate test
- `test_keeper_sandbox_docker_route`

Source-level boundary tests prevent regressions in layer ownership:

- `test_keeper_sandbox_boundary_policy`
- `test_keeper_sandbox_runner`

The boundary test intentionally fails if:

- tool code reintroduces Docker path literals or profile detection;
- status/sandbox-status surfaces bypass TOML-overlaid effective keeper meta;
- workspace repo-path helpers reintroduce Docker container-root construction
  or sandbox-profile parsing;
- Docker shell code re-exports generic command classification or parses
  raw shell commands directly;
- typed Execute or SearchFiles ops construct Shell IR outside
  `Keeper_tool_execute_shell_ir`;
- `shared shell compatibility facade` source files return;
- SearchFiles ops or GitHub `Execute` routes cwd/path resolution outside
  `Agent_tool_execute_path`;
- production shell modules bypass the dedicated op, timeout, runtime-path, or
  path owner modules;
- keeper modules outside `Agent_tool_execute_command_parse` call
  `Exec_policy.parse_string_to_ir`;
- keeper modules outside `Agent_tool_execute_command_words` call
  `Exec_policy_mutation_classifier`;
- PR/GitHub tool code calls `Keeper_sandbox_docker` or selects Docker via
  `meta.sandbox_profile = Docker`;
- typed Shell IR backend target helpers are coupled to a `tool_execute`
  module name;
- sandbox backend failure recording is coupled to a `shell_docker`
  module name;
- legacy sandbox aliases return to runtime parsing;
- keeper TOML parsing stops using the structured parser;
- command semantics reintroduces word extraction or string-split fallback
  parsing.
- completed or partial-completed runtime turns stop producing terminal runtime
  observation for receipts, or runtime-trust status stops surfacing receipt
  `runtime.selected_model` when decision telemetry is absent.
- recovered historical telemetry coverage gaps force source health to remain
  `coverage_gap` after a newer durable row exists for that source.
