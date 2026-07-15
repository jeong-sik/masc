# RFC-0274: Workspace base_path SSOT — retire env runtime read, thread Workspace.config

- Status: Draft
- Supersedes: —
- Related: #21798 (read/write path source asymmetry leak, same structure), RFC-0029 (env-knob unification, separate axis), RFC-0032 (env-knob unification, separate domain), RFC-0085 PR-8 (route path-derived env reads through `Host_config.from_env`)

## 1. Problem

Two state spaces carry the workspace base path, and they are never synchronized at runtime:

- **Write path**: `Mcp_server.set_workspace_config` (`lib/mcp_server.ml:492`) performs `Atomic.set state.workspace_config config`. It does not call `Unix.putenv MASC_BASE_PATH`.
- **Read path**: `Env_config_core.base_path ()` (`lib/config/env_config_core.ml:376`) reads `MASC_BASE_PATH` / `MASC_BASE_PATH_INPUT` via `raw_value_opt` (env → `Sys.getenv_opt` → `Config_boot_overrides`). It never consults the `Workspace.config` Atomic.

Runtime workspace switches (`lib/mcp_tool_runtime_workspace.ml:100,104`, reached via the `masc_start` tool route `lib/mcp_tool_runtime.ml:122`) therefore leave every `base_path ()` call site reading the **stale boot-time env** instead of the switched workspace. This is a silent cross-workspace data leak — the same read/write source-asymmetry class as #21798.

The only production `putenv` sites are boot-time:
- `lib/workspace/workspace_utils_backend_setup.ml:117-119` — gated behind `running_under_test_executable ()`, so it does **not** apply in production.
- `lib/server/server_runtime_bootstrap.ml:260` — runs once at bootstrap.

After bootstrap there is no production path that re-syncs env when `set_workspace_config` mutates the Atomic.

### Two additional direct-read leaks

Two sites bypass `Env_config_core.base_path ()` and read `MASC_BASE_PATH` directly via `Sys.getenv_opt`, so they would not be fixed by changing `base_path ()` alone:
- `lib/shutdown_hooks.ml:142-147` — shutdown janitor.
- `lib/tool_library.ml:79` — tool library root.

These must be migrated to the same `Workspace.config.base_path` source.

### A third env-read surface: `Host_config.from_env` / `base_path_source_opt`

`Host_config.host ()` (`lib/host_config/host_config.ml:60`, aliased as `from_env` at `:108`) reads the workspace path via `Env_config_core.base_path_source_opt ()` (`:68`). This is a sibling reader to `base_path ()`: it resolves `MASC_BASE_PATH` / `MASC_BASE_PATH_INPUT` from env at every call (it is not memoized). Runtime callers such as `voice_config`, `keeper_voice_local`, `tool_bridge`, `tool_library`, `keeper_artifact_hydrator`, `config_dir_resolver`, `server_routes_http_runtime_health_helpers`, and `server_dashboard_http_runtime_info.ml:1368,1606` therefore also read the stale boot-time base_path after `set_workspace_config`. This is the same #21798 leak class and is in scope for this RFC.

## 2. Proposal

Retire `Env_config_core.base_path ()` as a **runtime** read. Thread `Workspace.config.base_path` through the call sites so the in-memory Atomic becomes the single runtime source of truth.

- Keep `MASC_BASE_PATH` env as the **boot-time** source only (bootstrap putenv at `server_runtime_bootstrap.ml:260` and the test-gated `workspace_utils_backend_setup.ml:117` populate the initial `Workspace.config`). After boot, env is no longer read for the workspace path.
- `Env_config_core.base_path_opt ()` and `Env_config_core.base_path_source_opt ()` are retained for bootstrap-only callers (those that run before any `Workspace.config` exists). Runtime callers are migrated off them.
- Read semantics are explicit: the default is **per-operation read-through** (`Atomic.get state.workspace_config` at the point of use). A long-lived fiber may use a documented **per-fiber/per-pass snapshot** via a captured `~base_path`, but that choice must be explicit and reviewed.

### Site classification (16 runtime call sites, 14 modules)

| Pattern | Sites | Threading cost |
|---|---|---|
| `\| None -> base_path ()` (caller already has `?base_path` option) | `dashboard_verification.ml:163`, `keeper_runtime_contract.ml:206`, `keeper_approval_queue.ml:109` | Low — the `None` arm already implies an explicit-path option exists; replace the env fallback with a required `~base_path` from the caller's `Workspace.config`. |
| `Filename.concat (base_path ()) "..."` (absolute path resolve) | `eval_calibration.ml:103`, `channel_gate_discord_names.ml:22`, `channel_gate_imessage_state.ml:31`, `channel_gate_sidecar_state.ml:43` | Medium — thread `~base_path` into the resolver; callers (gate init, eval harness) obtain it from `Workspace.config`. |
| `let base_path = base_path () in` (local binding in runtime modules) | `runtime_transport.ml:189`, `runtime_transport_authorization.ml:58`, `runtime_observation.ml:473`, `runtime_transport_runtime_mcp_policy_of_tool_names.ml:42,99` | Medium — these modules already hold per-request context; thread `~base_path` from the request `Workspace.config`. |
| Single-call helpers | `board_paths.ml:6` (`board_base_path`), `thompson_sampling.ml:100`, `keeper_transition_audit.ml:79` | Low–Medium — add `~base_path` param, update callers. |

Comments/docstrings referencing `Env_config_core.base_path` (not calls): `env_config_core.ml:364`, `board_paths.mli:3`, `workspace_utils_paths_backend.ml:6`, `channel_gate_discord_names.mli:25` — updated to point at the new SSOT, no behavior change.

## 3. Non-goals

- Removing `MASC_BASE_PATH` env entirely. It remains the boot-time input and the test-isolation contract (`#9903`). This RFC only stops reading it at **runtime after boot**.
- Changing `Config_boot_overrides` semantics. Boot-override precedence (env > boot_override > default) is preserved for the boot path.
- The 340 broader `base_path` token matches in `lib/` (mostly `config.base_path` record access and `~base_path` labeled args — already correct). Only the 16 `Env_config_core.base_path ()` *call* sites, the 2 direct `Sys.getenv_opt` leaks, and the `Host_config.from_env` / `Env_config_core.base_path_source_opt` base_path surface are in scope.
- Reconciling the full `Host_config.from_env` env-read contract with RFC-0085 PR-8 is a coordination concern; this RFC only changes how the `base_path` field is sourced, leaving other host fields (`home`, `run_dir`, `assets_dir`, etc.) to RFC-0085.
- Caching/perf (P1-6 class). This RFC is a correctness/leak fix.

## 4. Migration

Phased so the tree stays green:

1. **Wave A — fallback sites** (lowest cost, caller already has `?base_path`): `dashboard_verification`, `keeper_runtime_contract`, `keeper_approval_queue`. Add a required `~base_path` where the `None` arm currently calls env; callers pass `config.base_path`.
2. **Wave B — absolute-path resolvers**: gate modules, `eval_calibration`. Thread `~base_path`.
3. **Wave C — runtime transport/observation modules**: thread `~base_path` from per-request `Workspace.config`.
4. **Wave D — direct `Sys.getenv_opt` leaks**: `shutdown_hooks`, `tool_library`.
   - `tool_library.ml:79`: migrate the `Sys.getenv_opt "MASC_BASE_PATH"` branch to read from `Workspace.config.base_path`, but **preserve** the existing fallback to `(Host_config.host ()).sandbox_workspace_root` when no explicit workspace path is available. Do not flatten to unconditional `base_path ()`-like raise-on-None semantics.
   - `shutdown_hooks.ml:142-147`: migrate the `Sys.getenv_opt "MASC_BASE_PATH"` read to use the last-known `Workspace.config.base_path` captured at shutdown-registration time, but **preserve** the empty/relative-path safety no-op semantics (do not raise; log and skip tmp cleanup).
5. **Wave E — `Host_config.from_env` base_path reads**: `voice_config`, `keeper_voice_local`, `tool_bridge`, `keeper_artifact_hydrator`, `config_dir_resolver`, `server_routes_http_runtime_health_helpers`, `server_dashboard_http_runtime_info`, and other `from_env ().base_path` callers. Route base_path reads through `Workspace.config.base_path` (per-operation read-through) or an explicit `~base_path` argument before falling back to `Host_config` for non-base_path host fields. Coordinate with RFC-0085 PR-8 so the `config_dir_resolver` "route path-derived env reads through `Host_config.from_env`" boundary is updated to take `base_path` as an explicit input rather than re-resolving it from env.
6. **Retire**: after all runtime callers migrate, mark `Env_config_core.base_path_opt` and `base_path_source_opt` bootstrap-only in the mli and remove runtime `base_path ()` / `base_path_source_opt` callers.

Each wave is independently mergeable.

## 5. Verification

- **Reproduction test**: switch `Workspace.config` via `set_workspace_config` in a test, then assert a migrated call site reads the **new** base_path, not the boot env. This test fails on `main` today (demonstrating the leak) and passes after migration. Same pattern as the #21798 leak-reproduction test.
- `check-determinism-contract` and existing workspace-isolation tests must stay green.
- A workspace-switch integration test that exercises the `masc_start` route and reads from a Wave-A/B/C site.
- **Static acceptance check**: `rg 'MASC_BASE_PATH' lib/` returns only bootstrap allow-listed sites and test-only `resolve ?base_path ()` callers; `Env_config_core.base_path ()`, `Env_config_core.base_path_source_opt`, `Sys.getenv_opt "MASC_BASE_PATH"`, and `Host_config.from_env ().base_path` are absent outside bootstrap.

## 6. Acceptance

- Zero runtime call sites of `Env_config_core.base_path ()` or `Env_config_core.base_path_source_opt` outside bootstrap.
- Zero direct `Sys.getenv_opt "MASC_BASE_PATH"` reads outside bootstrap (`shutdown_hooks`, `tool_library` migrated), and zero use of `Host_config.from_env ().base_path` as a runtime SSOT (migrated to `Workspace.config.base_path` or explicit `~base_path`).
- Static acceptance check passes: `rg 'MASC_BASE_PATH' lib/` minus bootstrap/test allow-list is empty.
- Each migrated base_path read site is classified in review as either **per-operation read-through** (obtains `Workspace.config` via `Atomic.get` immediately before use) or an explicit **per-fiber/per-pass snapshot** (captured in a `~base_path` argument and documented as intentional). No site may implicitly capture a stale config.
- Reproduction test present and passing.
- No regression in workspace-isolation tests.

## Why not the short-form putenv sync

Adding `Unix.putenv base_path_env_key` to `set_workspace_config` would stop the leak in one line, but it preserves the two-state-space split: env remains a runtime read, so any future direct `Sys.getenv_opt` or `Host_config.from_env` read (like the sites found here) re-introduces the leak silently. Threading `Workspace.config.base_path` makes the in-memory Atomic the single runtime SSOT, so a second reader cannot drift. This matches the #21798 precedent (thread + required entry + reproduction test) over a one-line env sync.
