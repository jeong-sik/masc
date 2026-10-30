---
rfc: "0274"
status: Draft
---

# RFC-0274: Workspace base_path SSOT — retire env runtime read, thread Workspace.config

- Status: Draft
- Supersedes: —
- Related: RFC workspace-root-resolution (the order an entry point uses to choose the root; this RFC owns every read after that choice), #21798 (read/write source asymmetry, same structure), RFC-0085 PR-8 (`Host_config.from_env` boundary)
- Starts after: RFC workspace-root-resolution stage 3, which removed `MASC_BASE_PATH_INPUT` from lib, bin and the shipped scripts (#36565, merged; #36571 and the batches after it clear the remaining test-only setters). Everything below describes the tree after that.

## 1. Problem

A process serves one workspace root, and two mechanisms keep it that way.

- `Workspace_utils_backend_setup.resolve_masc_base_path` returns `resolved_base_path_cache`
  whenever the cache is set, whatever path it was asked about. Every entry point sets the
  cache (`publish_workspace_root` and `run_cmd` in `bin/main_eio.ml`, `bin/main_stdio_eio.ml`,
  `bin/masc_tui.ml`, `server_runtime_bootstrap`). `test_workspace_base_path_cache` pins
  this.
- `Mcp_server.set_workspace_config` refuses a config whose `.masc` root differs from
  `workspace_runtime.process_masc_root` with `Workspace_masc_root_mismatch`.

Because the first mechanism runs before the second, `masc_start path=/other` is not
refused in production. `Workspace.default_config "/other"` builds a config whose
`base_path` is the cached root and whose `workspace_path` is `/other`; the root check
passes and the tool reports success while every store keeps using the process root.

The root is also not a value lib code receives. Lib code re-derives it from the process
environment on each read, so every entry point copies its choice into `MASC_BASE_PATH`
(and into the cache above) before lib code runs.

### 1.1 Entry points write the environment by hand

Production writes of `MASC_BASE_PATH`:

| Site | When |
|---|---|
| `bin/main_eio.ml` `publish_workspace_root` | the shared `--base-path` term, after `Workspace_root.resolve_current` |
| `bin/main_eio.ml` `run_cmd` | server start, after canonicalization |
| `bin/main_eio.ml` `voice_verify_cmd_exit` | only when `--base-path` was given |
| `bin/main_stdio_eio.ml` `run_cmd` | stdio server start |
| `bin/masc_tui.ml` `main` | TUI start |
| `lib/server/server_runtime_bootstrap.ml` `create_server_state` | server bootstrap, again |

`bin/main_eio.ml` `run_cmd` and `bin/main_stdio_eio.ml` `run_cmd` also write
`MASC_BASE_PATH_RESOLUTION_SOURCE`, which `server_base_path_diagnostics` reads.
`Workspace_utils_backend_setup.sync_test_base_path_env` writes `MASC_BASE_PATH` inside
test executables.

A command that does not write the variable reads whatever the shell exported, or the
fallbacks in §1.2. This has already happened. On 2026-09-13, `masc voice-verify` run
inside a workspace with only `HOME` and `PATH` set answered "voice config missing"
while the section was present. The comment above the `voice_verify_cmd_exit` write
records that measurement. The fix added one more write site rather than removing the
need for one.

### 1.2 Lib resolves the root again, in orders of its own

- `Env_config_core.base_path_source_opt` answers `MASC_BASE_PATH`, then the recorded
  default. It has no current-directory step, unlike `Workspace_root` (flag,
  `MASC_BASE_PATH`, a current directory holding `.masc/config`, the recorded default).
  `Host_config.host ()` derives `base_path`, `base_path_raw` and `sandbox_workspace_root`
  from it on every call, and `resolve_masc_base_path` reads it when the cache is unset.
- `Config_dir_resolver.effective_env_base_path` reads `MASC_BASE_PATH` and falls back to
  `Host_config`. `current_env_base_path_opt` wraps it in
  `sanitize_inherited_test_base_path_opt`, and `initial_env_base_path` is evaluated at
  module initialisation, so that a test executable does not read the developer's shell
  workspace. `inputs_from_env` feeds `Config_dir_resolver.resolve`.
- `Config_dir_resolver.base_path_or_cwd` returns the current directory when nothing
  answers. Callers: `voice_config`, `server_browser_webdriver`, `mcp_tool_runtime_workspace`,
  `bin/masc_checkpoint_purge.ml`, `bin/masc_cost.ml`, `bin/masc_tui_theme_catalog.ml`.
  A missing write silently becomes the launch directory.

### 1.3 Stores bind to whatever the environment says

- `Eval_calibration.get_store`, the wake payload store in `Dashboard_harness_health`,
  `Keeper_transition_audit.get_default_store` and the `Keeper_voice_local` singleton are
  opened on first use from the environment and kept in one `Atomic`; the first successful
  reader decides the directory for the rest of the process.
- `Tool_assignment_telemetry.get_or_create_runtime` reads the environment on every call
  and reopens its store when the answer changes, so a change of the environment moves it
  mid-process.

Each store has a `For_testing` reset or setter so tests can move between workspaces.

## 2. Proposal

The root is a value, chosen once and passed down.

- The entry point obtains a `Workspace_root.t` and passes `root` into the server, stdio,
  TUI and subcommand runners. `MASC_BASE_PATH` is read by `Workspace_root.observe` and by
  nothing else in the process.
- A lib site that needs the root takes `~base_path` (or a `Workspace.config`) from its
  caller. Because the root cannot change inside a process (§1), capturing it once when a
  long-lived service is constructed and reading it per operation give the same answer;
  the RFC does not distinguish the two.
- A store is looked up by the `base_path` it is given, so two workspaces in one test
  process get two stores and production gets one. The `For_testing` resets of §1.3 are
  deleted once no test needs them.
- `Workspace.default_config` builds the config for the path it is given. With the cache
  gone, `masc_start path=/other` reaches `validate_workspace_config` and is refused with
  `Workspace_masc_root_mismatch` instead of reporting success.
- Diagnostics that show what the operator typed read `Server_startup_state.input_base_path`
  and the config, and the resolution source travels as `Workspace_root.source`, not the
  environment.
- The process writes `MASC_BASE_PATH` only into the environment of a child process it
  starts (`Keeper_sandbox_runtime_setup`, the sidecar route, `Runtime_setup_batch`). The
  child resolves it again as its own `Environment` source.

## 3. Site inventory

Runtime sites that read the root from the environment, grouped by the PR that migrates
them. "In reach" means a `Workspace.config` or `~base_path` is already in the function or
its direct caller. Each lib batch touches at most five production files besides the
callers that only gain an argument; a batch that grows past that is split before review.

| Batch | Site | Reads | In reach |
|---|---|---|---|
| 1 | `Keeper_transition_audit.get_default_store` and its callers (`keeper_registry`, `keeper_turn_fsm`, `server_dashboard_http_keeper_api`, `keeper_runtime_trust_snapshot`, `dashboard_http_keeper_outcomes`) | `Env_config_core.base_path` | caller |
| 2 | `Eval_calibration.get_store` (`completion_authority_agent`); `Dashboard_harness_health` wake payload store, readers (`dashboard_http_keeper_outcomes`, `server_routes_http_routes_dashboard`) and writers (`keeper_wake_telemetry`, `keeper_keepalive_signal`, `keeper_agent_run_phase0_telemetry`) | `Env_config_core.base_path` | caller |
| 3 | `Board_paths.board_base_path` (`board_votes`, `board_core`, `board_core_persist`) | `Env_config_core.base_path` | partial (`store.workspace_masc_dir`) |
| 4 | channel gate state paths (`channel_gate_{slack,discord,imessage,sidecar}_state`, stored as `unit -> string` in `channel_gate_binding_store`), `server_imessage_in_process_gateway` cursor path | `Env_config_core.resolve_against_base_path` | no |
| 5 | browser lane token path; `Tool_misc_web_fetch.offload_full_text` and the `handle` callers (`tool_misc`, `tool_misc_web_enrichment`, `verification_authority_tools`, `fusion_agent_core`, `keeper_tool_in_process_runtime`); delete `resolve_against_base_path` | `Env_config_core.resolve_against_base_path`, `Env_config_core.base_path` | no |
| 6 | `Tool_assignment_telemetry.get_or_create_runtime` (`mcp_server_eio_call_tool`, `mcp_server_eio_protocol`, `keeper_run_tools_setup`, `workspace_metric_hooks`); rewrite `test_store_follows_the_base_path` to pass `~base_path` | `Env_config.base_path` per call | caller |
| 7 | `Shutdown_hooks.run_all` tmp cleanup | `Sys.getenv_opt "MASC_BASE_PATH"` | no |
| 8 | `Voice_config` path lookups, `Voice_bridge_core.masc_base_dir`, `Keeper_voice_local` singleton, `keeper_tool_voice_runtime` | `Host_config`, `base_path_or_cwd` | no |
| 9 | diagnostics: `server_dashboard_http_runtime_info` resolution JSON, `server_routes_http_runtime_health_helpers.health_path_diagnostics`, `server_dashboard_http_core_shell_bootstrap.dashboard_shell_paths_json`, `server_runtime_bootstrap` path diagnostics (`base_path_raw`), `server_base_path_diagnostics` resolution source | `base_path_source_opt`, `Host_config`, `MASC_BASE_PATH_RESOLUTION_SOURCE` | yes |
| 10 | `Config_dir_resolver.resolve ~base_path` and keeper callers: `keeper_types_profile`, `keeper_run_context`, `keeper_runtime_config`, `keeper_vision_tool` | `inputs_from_env` | caller |
| 11 | `Config_dir_resolver.resolve` server callers: `runtime`, `connector_trigger_policy`, `server_slack_poll_lane`, `server_routes_http_routes_activity`, `server_runtime_bootstrap` | `inputs_from_env` | caller |
| 12 | server fallbacks: `server_routes_http_sidecar_paths.runtime_base_path_result`, `server_mcp_transport_http_session` sessions file, `Server_browser_webdriver.start`, `mcp_tool_runtime_workspace` path expansion, and the `default_base_path ()` arms in `server_routes_http_common`, `server_h2_gateway`, `server_routes_http_routes_frontend` | `current_env_base_path_opt`, `resolve_masc_base_path`, `base_path_or_cwd` | partial |
| 13 | bin readers: `masc_checkpoint_purge`, `masc_cost`, `masc_tui_theme_catalog`, `masc_tui_config`, `fusion_run`, `masc_lane_cli_probe`, `keeper_capability_probe_cli`, the `base_path_source_opt` reads in `main_eio` sandbox and setup commands; `Browser_host.resolve_config` takes the root from its CLI flag instead of `Env_config_core.base_path` | `base_path_or_cwd`, `current_env_base_path_opt`, `base_path_source_opt` | entry point |
| 14 | entry points and retirement (§4) | — | — |

`Host_config.sandbox_workspace_root` carries the same value, so
`keeper_sandbox_containment` and `exec_policy_paths` move with the batch that owns
their caller. Batch 9 needs `Server_startup_state.input_base_path` (#36457).

Allowed to keep reading the environment: `Workspace_root.observe`. Allowed to write it:
the child-environment builders named in §2. `env_keeper_scrub` and `env_config_snapshot`
name the key without reading the root.

## 4. Migration

Each batch is one PR, green on `main` by itself, in the order of §3. Leaf stores come
first so later batches pass a value that already exists.

Batch 14 removes what the earlier batches made unused:

- every `Unix.putenv` of `MASC_BASE_PATH` and `MASC_BASE_PATH_RESOLUTION_SOURCE` in §1.1,
  `publish_workspace_root`, `resolved_base_path_cache`, `cache_resolved_base_path`, the
  cache arm of `resolve_masc_base_path`, `sync_test_base_path_env`, and
  `test_workspace_base_path_cache`;
- `Env_config_core.base_path`, `base_path_opt`, `base_path_raw_opt`,
  `base_path_source_opt`, and the `base_path` and `base_path_raw` fields of `Host_config.host`;
- `Host_config.resolve`, which has no production caller and reads `MASC_BASE_PATH`;
- `Config_dir_resolver.effective_env_base_path`, `initial_env_base_path`,
  `sanitize_inherited_test_base_path_opt`, `current_env_base_path_opt`, the base path part
  of `inputs_from_env`, `base_path_or_cwd`, and the `base_path` arm of `fallback_cwd_from_env`;
- the `For_testing` store resets of §1.3 that no test still calls.

`Env_config_core.persisted_default_base_path` stays; `Workspace_root.observe` reads it.

## 5. Verification

- Per batch: a test sets `MASC_BASE_PATH` to one temporary directory, passes another as
  `~base_path`, and asserts the migrated site reads and writes under the passed one. On
  `main` the same site follows the environment.
- Batch 8: with only `HOME` and `PATH` set, `masc voice-verify --base-path <ws>` run from
  another directory, and `masc voice-verify` run inside `<ws>`, both read the voice
  section of `<ws>` after the write in `voice_verify_cmd_exit` is gone.
- Batch 12: `masc_start path=<other directory>` on a running server is refused with
  `Workspace_masc_root_mismatch` once the cache arm is gone; today it reports success.
- Batch 14: `rg '"MASC_BASE_PATH"|base_path_env_key' lib bin` lists only
  `Workspace_root.observe`, the child-environment builders (`keeper_sandbox_runtime_setup`,
  `server_routes_http_routes_sidecar`, `runtime_setup_batch`), `env_keeper_scrub` and
  `env_config_snapshot`; `rg 'putenv' lib bin | rg 'MASC_BASE_PATH'` is empty.
- `scripts/ci/check_env_reads_below_config.py` baseline shrinks with each batch and is
  rewritten in the same PR.

## 6. Non-goals

- Changing the order an entry point uses to choose the root. RFC workspace-root-resolution
  owns it.
- Removing `MASC_BASE_PATH` as an operator input or as the child-process contract.
- Host fields other than the workspace root (`home`, `run_dir`, `assets_dir`); RFC-0085 owns them.

## 7. Alternatives

- **Write the variable from `set_workspace_config`.** The root cannot change there (§1),
  so this adds nothing and leaves every write site in §1.1.
- **A write-once process cell instead of the environment.** One already exists:
  `resolved_base_path_cache`. It is why `masc_start path=/other` reports success while
  binding the process root (§1): a cell answers every question with its one value, so a
  mismatched request is absorbed instead of refused. A cell also keeps the order
  dependency (a read before the write has no answer) and hides the dependency from
  signatures.
- **Keep the environment and add a write to each new entry point.** This is the current
  state. The 2026-09-13 `voice-verify` measurement shows a new entry point reads another
  workspace until someone notices.
