# Keeper Sandbox Boundary Policy

Last updated: 2026-11-05

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
| `Keeper_sandbox_shell_ir_target` | Backend target construction for typed Shell IR dispatch | Tool-surface ownership, command parsing, `tool_execute` policy |
| `Keeper_sandbox_runner` | Effective sandbox profile and the backend name a write reports (`sandbox_backend_via`) | Git/remote workflow semantics, tool input validation, command parsing ownership |
| `Keeper_sandbox_docker` | Docker runtime setup, mounts, network mode, command execution, Docker result envelope | Generic command classification or cwd policy ownership |
| `Keeper_sandbox_exec_failure` | Sandbox backend failure messages and registry recording | Tool-surface naming, command classification, shell-specific policy |

## Deterministic Rules

- Canonical sandbox profiles are `docker`, `microvm` and `remote_ssh`.
- Legacy aliases are rejected, not warned and reinterpreted.
- Keeper TOML is parsed with `Otoml`, not ad hoc string parsing.
- Docker container roots are path projections from the config contract,
  not literals in tool code.
- Docker subprocess status, stdout, and stderr are surfaced from one execution.
  Rendered error text must not trigger retries or output suppression; typed
  Unix I/O errors are handled only at the process boundary.
- Per-command `git`/`gh` behavior is command semantics, not a sandbox
  profile.
- Tool modules must not branch on `meta.sandbox_profile = Docker` or call
  `Keeper_sandbox_docker` directly. They read the profile through
  `Keeper_sandbox_runner.effective_sandbox_profile` and dispatch through
  `Keeper_sandbox_shell_ir_target` or `Keeper_sandbox_read_runner`.
- Status, list, operator, and sandbox-status surfaces must read effective
  keeper meta via `Keeper_meta_store.read_effective_meta*`, not raw persisted
  JSON, before displaying `sandbox_profile`, `network_mode`, `tool_access`, or
  sandbox live state. Persisted runtime JSON intentionally omits TOML-owned
  fields, so a raw read returns the decoder's placeholder profile (`docker`)
  whatever profile the keeper TOML declares.
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
