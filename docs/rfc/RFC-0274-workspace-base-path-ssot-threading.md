---
rfc: "0274"
status: Draft
---

# RFC-0274: Workspace base_path SSOT — retire env runtime read, thread Workspace.config

- Status: Draft
- Supersedes: —
- Related: RFC workspace-root-resolution (the order an entry point uses to choose the root; this RFC owns every read after that choice), #21798 (read/write source asymmetry, same structure), RFC-0085 PR-8 (`Host_config.from_env` boundary)

## 1. Problem

A process serves exactly one workspace root. `Mcp_server.set_workspace_config` calls
`validate_workspace_config`, which refuses any config whose `.masc` root differs from
`workspace_runtime.process_masc_root` with `Workspace_masc_root_mismatch`. The
`masc_start` tool therefore cannot move a running server to another directory, and no
code path changes the root after the state is created.

The root is still not a value that lib code receives. Lib code re-derives it from the
process environment on each read, so every entry point has to copy its choice into
`MASC_BASE_PATH` before any lib code runs.

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

`Workspace_utils_backend_setup.sync_test_base_path_env` writes it too, but only inside
test executables.

A command that does not write the variable reads whatever the shell exported, or the
fallbacks in §1.2. This has already happened. On 2026-09-13, `masc voice-verify` run
inside a workspace with only `HOME` and `PATH` set answered "voice config missing"
while the section was present. The comment above the `voice_verify_cmd_exit` write
records that measurement. The fix added one more write site rather than removing the
need for one.

### 1.2 Lib has a second resolver with a different order

The environment readers do not share the entry point's order.

- `Env_config_core.base_path_source_opt` answers `MASC_BASE_PATH`, then the recorded
  default. It has no current-directory step, so its order differs from
  `Workspace_root` (flag, `MASC_BASE_PATH`, a current directory holding `.masc/config`,
  the recorded default).
- `Host_config.host ()` derives `base_path` and `sandbox_workspace_root` from that
  resolver on every call.
- `Config_dir_resolver.base_path_or_cwd` returns the current directory when the
  resolver answers nothing. `voice_config` and `server_browser_webdriver` use it, so a
  missing write silently becomes the launch directory.
- `Config_dir_resolver.initial_env_base_path` is evaluated at module initialisation, and
  `sanitize_inherited_test_base_path_opt` exists only so that a test executable does not
  read the developer's shell workspace through these readers.

### 1.3 Process-wide stores are keyed by nothing

`Eval_calibration.get_store`, the wake payload store in `Dashboard_harness_health`,
`Keeper_transition_audit.get_default_store`, `Tool_assignment_telemetry.get_or_create_runtime`
and the `Keeper_voice_local` singleton are created on first use from the environment and
kept in one `Atomic`. The first reader's environment decides the directory for the rest
of the process. In production this equals the root only because every entry point wrote
the variable first; a test process that opens two workspaces gets the first one twice.

## 2. Proposal

The root is a value, chosen once and passed down.

- The entry point obtains a `Workspace_root.t` and passes `root` into the server, stdio,
  TUI and subcommand runners. `MASC_BASE_PATH` is read by `Workspace_root.observe` and by
  nothing else in the process.
- A lib site that needs the root takes `~base_path` (or a `Workspace.config`) from its
  caller. Because the root cannot change inside a process (§1), capturing it once when a
  long-lived service is constructed and reading it per operation give the same answer;
  the RFC does not distinguish the two.
- A lazily created store is looked up by the `base_path` it is given, so two workspaces
  in one test process get two stores and production gets one.
- Diagnostics that show what the operator typed read `Server_startup_state.input_base_path`
  and the config, not the environment.
- The process writes `MASC_BASE_PATH` only into the environment of a child process it
  starts (`Keeper_sandbox_runtime_setup`, the sidecar route). The child resolves it again
  as its own `Environment` source.

## 3. Site inventory

Runtime sites that read the root from the environment, grouped by the PR that migrates
them. "In reach" means a `Workspace.config` or `~base_path` is already in the function or
its direct caller.

| Batch | Site | Reads | In reach |
|---|---|---|---|
| 1 | `Keeper_transition_audit.get_default_store` and its `append_now` callers (`keeper_registry`, `keeper_turn_fsm`, `server_dashboard_http_keeper_api`, `keeper_runtime_trust_snapshot`) | `Env_config_core.base_path` | caller |
| 2 | `Eval_calibration.get_store`; `Dashboard_harness_health` wake payload store (`completion_authority_agent`, `dashboard_http_keeper_outcomes`, `server_routes_http_routes_dashboard`) | `Env_config_core.base_path` | caller |
| 3 | `Board_paths.board_base_path` (`board_votes`, `board_core`, `board_core_persist`) | `Env_config_core.base_path` | partial (`store.workspace_masc_dir`) |
| 4 | channel gate state paths (`channel_gate_{slack,discord,imessage,sidecar}_state`, stored as `unit -> string` in `channel_gate_binding_store`), `server_imessage_in_process_gateway` cursor path | `Env_config_core.resolve_against_base_path` | no |
| 5 | browser lane token path; `Tool_misc_web_fetch.offload_full_text` and the `handle` callers (`tool_misc`, `tool_misc_web_enrichment`, `verification_authority_tools`, `fusion_agent_core`); delete `resolve_against_base_path` | `Env_config_core.resolve_against_base_path` | no |
| 6 | `Tool_assignment_telemetry.get_or_create_runtime` (`mcp_server_eio_call_tool`, `mcp_server_eio_protocol`, `keeper_run_tools_setup`, `workspace_metric_hooks`) | `Env_config_core.base_path` | caller |
| 7 | `Tool_library.workspace_root` (`mcp_server_eio_execute`, `keeper_tool_in_process_runtime`, `keeper_tag_dispatch`); `Shutdown_hooks.run_all` tmp cleanup | `Sys.getenv_opt "MASC_BASE_PATH"` | caller / no |
| 8 | `Voice_config` path lookups, `Voice_bridge_core.masc_base_dir`, `Keeper_voice_local` singleton, `keeper_tool_voice_runtime` | `Host_config`, `base_path_or_cwd` | no |
| 9 | `server_dashboard_http_runtime_info` resolution JSON, `server_routes_http_runtime_health_helpers.health_path_diagnostics`, `server_dashboard_http_core_shell_bootstrap.dashboard_shell_paths_json`, `server_routes_http_sidecar_paths.runtime_base_path_result` | `base_path_source_opt`, `Host_config`, `current_env_base_path_opt` | yes |
| 10 | `Config_dir_resolver.resolve` and its path helpers; `server_mcp_transport_http_session` sessions file; `Server_browser_webdriver.start` | `effective_env_base_path`, `base_path_or_cwd` | no |
| 11 | entry points and retirement (§4) | — | — |

`Host_config.sandbox_workspace_root` carries the same value, so `tool_library`,
`keeper_sandbox_containment` and `exec_policy_paths` move with the batch that owns
their caller. Batch 9 needs `Server_startup_state.input_base_path`.

Allowed to keep reading the environment: `Workspace_root.observe` (entry point),
`browser_host` configuration (its own CLI), and the child-environment builders named in §2.

## 4. Migration

Each batch is one PR of at most five production files, green on `main` by itself, in the
order of §3. Leaf stores come first so later batches pass a value that already exists.

Batch 11 removes what the earlier batches made unused:

- every `Unix.putenv` of `MASC_BASE_PATH` in §1.1, `publish_workspace_root`,
  `Workspace_utils_backend_setup.cache_resolved_base_path` and `sync_test_base_path_env`;
- `Env_config_core.base_path`, `base_path_opt`, `base_path_raw_opt`,
  `base_path_source_opt` and the `base_path` field of `Host_config.host`;
- `Config_dir_resolver.effective_env_base_path`, `initial_env_base_path`,
  `sanitize_inherited_test_base_path_opt`, `base_path_or_cwd`, and the `base_path` arm
  of `fallback_cwd_from_env`.

`Env_config_core.persisted_default_base_path` stays; `Workspace_root.observe` reads it.

## 5. Verification

- Per batch: a test sets `MASC_BASE_PATH` to one temporary directory, passes another as
  `~base_path`, and asserts the migrated site reads and writes under the passed one. On
  `main` the same site follows the environment.
- Batch 8: with only `HOME` and `PATH` set, `masc voice-verify --base-path <ws>` run from
  another directory, and `masc voice-verify` run inside `<ws>`, both read the voice
  section of `<ws>` after the write in `voice_verify_cmd_exit` is gone.
- Batch 11: `rg 'base_path_env_key|"MASC_BASE_PATH"' lib bin` lists only
  `Workspace_root.observe`, the child-environment builders, `env_keeper_scrub` and
  `env_config_snapshot`; `rg 'putenv.*MASC_BASE_PATH|putenv Env_config_core.base_path_env_key' lib bin` is empty.
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
- **A write-once process cell instead of the environment.** It removes `putenv` but keeps
  the order dependency: a read before the write still has no answer, the signature still
  hides the dependency, and tests need a reset function to open a second workspace.
- **Keep the environment and add a write to each new entry point.** This is the current
  state. The 2026-09-13 `voice-verify` measurement shows a new entry point reads another
  workspace until someone notices.
