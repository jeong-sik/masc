---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/config/
  - lib/config/env_config.mli
  - start-masc.sh
---

# Boot, Path, and Runtime State Inventory

This document answers four operator questions:

- Which environment inputs and startup flags affect boot.
- Which path rules decide the active runtime root and config root.
- Where live state, logs, and audit artifacts land on disk.
- What the current host is actually using right now.

For day-to-day active-root and init diagnosis, use the launcher/env contract.
This document is the deeper inventory behind that operator flow.

Scope:

- Canonical behavior in this document is derived from code.
- "Current host audit" is a dated snapshot of the machine inspected on 2026-04-09.
- Primary runtime domains are `tasks`, `board`, `goals`, `keepers`, and the external-effect Gate.
- `team-sessions`, `local-workers`, `oas-runtime`, and `command-plane` are documented only as compatibility, historical, or execution-artifact lanes, not as the primary product concept.

## 1. Boot Inputs and Precedence

### 1.1 Inputs that decide roots and boot behavior

| Input | What it controls | Used by |
| --- | --- | --- |
| `--base-path` | Startup workspace root selection. `main_eio` exports this to `MASC_BASE_PATH`; runtime state is under `<base-path>/.masc`. | `bin/main_eio.ml`, all `.masc` path helpers |
| `MASC_BASE_PATH` | Runtime base path once the server is running. This is the workspace root, not the `.masc` directory itself. | `Env_config_core`, `Workspace_utils`, keeper/board/control-plane/logging paths |
| `MASC_CONFIG_DIR` | Explicit config root override. Highest-precedence config selector. | `Config_dir_resolver`, bootstrap, keeper/persona config resolution |
| `MASC_PERSONAS_DIR` | Explicit personas root override. | `Config_dir_resolver`, keeper/persona loading |
| `HOME` | Shell/user-home context for external tools and non-config artifact stores. | Host process environment |
| `MASC_WORKSPACE_ROOT`, `ME_ROOT`, `DUNE_SOURCEROOT` | Workspace discovery, knowledge paths, `scripts/sb` resolution. | `Env_config_core`, workspace paths |
| `MASC_HOST`, `MASC_HTTP_PORT`, `MASC_HTTP_BASE_URL` | Bind address and derived HTTP endpoint identity. | HTTP/bootstrap/provider routing |
| `MASC_ADMIN_TOKEN` | Privileged endpoint auth. | server auth |

Not every environment variable controls the same part of the runtime, but the
default operator contract is still boot-time unless a separate runtime control
plane exists. See [`ENV-CONTRACT.md`](./ENV-CONTRACT.md) for reload classes and
exceptions. The centralized inventory lives in `lib/config/env_config_*.ml`; a
repo-wide scan still finds additional ad-hoc environment reads outside those
modules.

### 1.2 Config root resolution

Low-level resolver precedence is:

1. `MASC_CONFIG_DIR`
2. `<MASC_BASE_PATH>/.masc/config`
3. missing/uninitialized `<base-path>/.masc/config`

Important boot behavior:

- If `MASC_CONFIG_DIR` is unset, bootstrap initializes `<MASC_BASE_PATH>/.masc/config`.
- Bootstrap copies only missing files from the versioned `config/` tree; it does not overwrite an existing file.
- Supported launchers and boot diagnostics should be read with a simpler operator contract:
  active config is `MASC_CONFIG_DIR` when set, otherwise `<MASC_BASE_PATH>/.masc/config`.
- This means a passive base-path config root can exist on disk even when it is not the active config root.
- There is no secondary operator config fallback. On shared hosts, use an
  explicit base path and expect live config under `<base-path>/.masc/config`.

### 1.3 Personas root resolution

Canonical personas-root precedence is:

1. `MASC_PERSONAS_DIR`
2. `<resolved CONFIG_ROOT>/personas`

Keeper bootstrap may also source keeper defaults from `CONFIG_ROOT/keepers/<name>.toml`, even when personas are resolved from the personas tree.

### 1.4 What the config root contains

The checked-in versioned seed config tree currently contains:

| Path | Purpose |
| --- | --- |
| `config/runtime.toml` | Provider/model runtime and routing defaults. |
| `config/keepers/*.toml` | Keeper defaults and policy-overridable profiles. |
| `config/personas/*` | Persona definitions and persona-specific profile data. |
| `config/prompts/*.md` | Versioned system prompt fragments and analysis/keeper prompt templates. |

`runtime.toml` is checked into the repo seed tree as a local-first example and
bootstrap default. Live authoring still happens in the active-root file at
`<active config root>/runtime.toml`; existing active roots are preserved and
are not overwritten by the seed.

### 1.3 runtime.toml — per-base-path startup keeper env seeding

All live startup-scoped `MASC_KEEPER_*` keeper runtime variables wired through
`Env_config_keeper` / `Keeper_config` can be set declaratively in
`<active config root>/runtime.toml`. The TOML file is loaded at server
startup by `Keeper_runtime_config.load_and_apply` (called from
`server_runtime_bootstrap.ml`) before any module that reads these env
vars initializes.

Operational contract:

- This file is `boot_static`, not hot-reloaded.
- The file seeds a process-local boot override store.
- Live tuning belongs in `Runtime_params`, not in parent-shell env edits.

**Precedence** (highest first):
1. Process env var (caller/CI override — never overwritten by TOML)
2. TOML value from `runtime.toml`
3. Hardcoded default in `Env_config_keeper` / `Keeper_keepalive`

Missing file is not an error (returns 0 overrides, uses env/defaults).
Parse errors log a warning and fall back to env defaults.
Legacy compatibility names are not TOML preemption keys. For example,
`MASC_KEEPER_AUTOBOT_MAX` is ignored here; `bootstrap.autoboot_max` writes
only the canonical `MASC_KEEPER_AUTOBOOT_MAX` boot override unless that exact
canonical process env var is already set.

**Sections** (80 knobs total):

| Section | Count | Key examples |
| --- | --- | --- |
| `[bootstrap]` | 4 | `enabled`, `max_scan`, `autoboot_max` |
| `[autonomous]` | 2 | `enabled`, `fairness_cooldown_sec` |
| `[reactive]` | 1 | `enabled` |
| `[heartbeat]` | 6 | `interval_sec`, `max_silence_sec`, `sleep_chunk_sec`, `board_wakeup_max` |
| `[health]` | 1 | `durable_queue_stale_sec` |
| `[wire_capture]` | 1 | `enabled` |
| `[proactive]` | 4 | `enabled`, `min_interval_sec`, `noop_backoff_max_shift`, `idle_decay_max_periods` |
| `[turn]` | 16 | `timeout_sec`, `stream_idle_timeout_sec`, `execution_idle_timeout_sec`, `chat_waiting_cap`, `temperature` |
| `[supervisor]` | 3 | `backoff_base_sec`, `backoff_max_sec`, `sweep_sec` |
| `[lifecycle]` | 1 | `dead_ttl_sec` |
| `[budget]` | 1 | `daily_usd` |
| `[metrics]` | 2 | `max_bytes`, `max_rotated` |
| `[memory]` | 6 | `max_notes`, `compact_trigger_bytes`, `consensus_pattern` |
| `[alert]` | 17 | `slack_enabled`, `slack_dm_user_id`, `github_enabled`, `github_min_score` |
| `[web_search]` | 8 | `provider`, `fallbacks`, `timeout_sec`, `rate_limit_max_calls` |
| `[debug]` | 1 | `enabled` |

**Example** (`<active config root>/runtime.toml`):

```toml
[autonomous]

[reactive]

[heartbeat]
board_wakeup_max = 4 # caps total non-explicit board wakeups after reason prioritization

[health]
durable_queue_stale_sec = 0.0 # default: any durable backlog degrades full health; raise to tolerate fresh handoff

[turn]
stream_idle_timeout_sec = 120
# Optional Agent.run no-progress guard. Tool timeouts live in the tool layer.
# execution_idle_timeout_sec = 300
tool_cost_max_usd = 1.25
llm_rerank = true

[watchdog]
stale_sec = 600
grace_sec = 900
```

`tool_cost_max_usd = 0` leaves the advisory cost threshold unset. Cost
thresholds are telemetry only and never gate keeper tool execution.

**Implementation**: `lib/keeper/keeper_runtime_config.ml` maintains a
`key_to_env` table mapping TOML dotted keys to env var names. Values
are recorded in a process-local boot override store so existing
`Env_config_*` and keeper helpers can resolve TOML-backed defaults
without mutating the parent environment.

## 2. Canonical Root and Path Resolution

### 2.1 Root formulas

- Default cluster runtime root: `<base-path>/.masc`
- Normal operator runbooks should name the base path explicitly; runtime state
  is then rooted at `<base-path>/.masc`.
- Named cluster runtime root: `<base-path>/.masc/clusters/<cluster_name>`
- Config root: resolved separately by the precedence chain above
- Personas root: resolved separately from the config root
- Planning root: `<base-path>/planning/<task_id>` (important outlier: not inside `.masc`)

### 2.2 Path matrix

| Artifact lane | Canonical path |
| --- | --- |
| Runtime root | `<base-path>/.masc` |
| Cluster root | `<base-path>/.masc/clusters/<cluster_name>` |
| Base-path config root | `<base-path>/.masc/config` |
| Keepers | `<runtime_root>/keepers` |
| Traces | `<runtime_root>/traces` |
| Playground | `<runtime_root>/playground/<keeper>/...` |
| Tasks/backlog | `<runtime_root>/tasks/backlog.json` |
| Task archive | `<runtime_root>/tasks-archive.json` |
| Agents | `<runtime_root>/agents` |
| Messages | `<runtime_root>/messages` |
| Current task pointer | `<runtime_root>/current_task` |
| Planning context | `<base-path>/planning/<task_id>/` |
| Runs | `<runtime_root>/runs/<task_id>/` |
| Board | `<runtime_root>/board_posts.jsonl`, `board_comments.jsonl`, `board_votes.jsonl` |
| Keeper Gate state | `<runtime_root>/gate/mode.json`, `gate/pending.json` |
| Control plane | `<runtime_root>/control-plane/` |
| Operator lane | `<runtime_root>/operator/` |
| Logs | `<runtime_root>/logs/` |
| Audit/tool logs | `<runtime_root>/audit/`, `tool_calls/`, `tool_usage/` |
| Auth | `<runtime_root>/auth/` |
| Connectors | `<runtime_root>/connectors/discord/` |
| Voice config | `<runtime_root>/voice_config.json` (where `<runtime_root>` = `MASC_BASE_PATH/.masc/`) |
| Voice audio | `<runtime_root>/audio/` (TTS output, auto-cleaned after 1h) |
| Voice sessions | `<runtime_root>/voice_sessions/<agent>.json` |
| Legacy compat | `<runtime_root>/team-sessions/`, `local-workers/`, `oas-runtime/` |

## 3. Runtime State by Domain

### 3.1 Tasks and Backlog

- `<runtime_root>/tasks/backlog.json`: active backlog state.
- `<runtime_root>/tasks-archive.json`: archived or cleaned-up tasks.
- `<runtime_root>/agents/`: agent membership and state snapshots.
- `<runtime_root>/messages/`: workspace and broadcast message artifacts.
- `<runtime_root>/current_task`: planning pointer for the current claimed task.
- `<base-path>/planning/<task_id>/`: planning-with-files context:
  - `task_plan.md`
  - `notes.md`
  - `errors.md`
  - `deliverable.md`
  - `context.json`
- `<runtime_root>/runs/<task_id>/`: execution-memory lane:
  - `run.json`
  - `plan.md`
  - `deliverable.md`
  - `log.jsonl`

Important outlier: planning data does not live under `.masc`; it lives under `<base-path>/planning/`.

### 3.2 Board

- `<runtime_root>/board_posts.jsonl`
- `<runtime_root>/board_comments.jsonl`
- `<runtime_root>/board_votes.jsonl`
- `<runtime_root>/mention_inbox.jsonl`

Notes:

- JSONL is the board backend. PostgreSQL board backend was removed; filesystem is the only supported lane.

### 3.3 Gate and HITL

- `<runtime_root>/gate/mode.json`
- `<runtime_root>/gate/pending.json`
- `<runtime_root>/audit-approvals/YYYY-MM/DD.jsonl`

The retired `governance*` trees are not active runtime inputs. Their presence on
disk is historical residue and must not recreate a runtime authority.

### 3.4 Keepers

- `<runtime_root>/keepers/<name>.json`: keeper meta/state.
- `<runtime_root>/keepers/<name>.decisions.jsonl`
- `<runtime_root>/keepers/<name>.memory.jsonl`
- `<runtime_root>/keepers/<name>.policy.jsonl`
- `<runtime_root>/keepers/<name>.feedback.jsonl`
- `<runtime_root>/keepers/<name>.tla-trace.jsonl`
- `<runtime_root>/keepers/<name>/metrics/YYYY-MM/DD.jsonl`
- `<runtime_root>/keepers/tool_usage/<name>.json`
- `<runtime_root>/traces/<trace_id>/`: turn history and checkpoints.
- `<runtime_root>/keeper_chat/<keeper>.jsonl`
- `<runtime_root>/evidence/<keeper>/<trace_id>/turn_XXX.json`

Playground and execution model:

- Keeper playground root: `<runtime_root>/playground/<keeper>/` (keeper-owned sandbox)
- Clone target for repo work: `<runtime_root>/playground/<keeper>/repos/<repo_name>`
- Additional scratch lane: `<runtime_root>/playground/<keeper>/mind/`
- Repo worktree workflow is separate and uses repo-local `.worktrees/<branch-or-task>/`

Allowed path model:

- `workspace` execution scope includes the keeper playground bundle, `<runtime_root>/keepers/<name>/`, `<runtime_root>/traces/`, and any explicit `allowed_paths`.
- Shell or bash execution is possible when tool policy allows it.
- Write access is still constrained by execution scope and allowed-path resolution.
- PR-submit flow accepts a repo `cwd` inside the keeper playground, not only classic `.worktrees/` paths.

### 3.5 Command Plane and Operator

- `<runtime_root>/control-plane/units.json`
- `<runtime_root>/control-plane/operations.json`
- `<runtime_root>/control-plane/intents.json`
- `<runtime_root>/control-plane/events.jsonl`
- `<runtime_root>/control-plane/detachments.json`
- `<runtime_root>/control-plane/decisions.json`
- `<runtime_root>/control-plane/search-stats.json`
- `<runtime_root>/control-plane/traces/`
- `<runtime_root>/operator/pending_confirms.json`
- `<runtime_root>/operator/action_log.jsonl`
- `<runtime_root>/swarm.json`
- `<runtime_root>/control-plane/swarm-live/`

### 3.6 Logs, Audit, Metrics, and Tool Traces

- `<runtime_root>/logs/`: service logs.
- `<runtime_root>/audit/YYYY-MM/DD.jsonl`
- `<runtime_root>/tool_calls/YYYY-MM/DD.jsonl`
- `<runtime_root>/tool_usage/YYYY-MM/DD.jsonl`
- `<runtime_root>/runtime_params.json`
- `<runtime_root>/param_audit.jsonl`
- `<runtime_root>/metrics/<agent>/YYYY-MM.jsonl`
- `<runtime_root>/drift_guard.jsonl`
- `<runtime_root>/costs.jsonl`
- `<runtime_root>/autonomy_stats.jsonl`

Current host note:

- The inspected host also contains auxiliary event and telemetry lanes such as `activity-events/`, `events/`, `telemetry/`, and `data/tool-metrics/`.
- Repo-local `masc/logs/` directories are non-canonical historical or
  harness captures. Live runtime service logs belong under `<runtime_root>/logs/`.

### 3.7 Auth, Connectors, and Voice

- `<runtime_root>/auth/`
  - `config.json`
  - `initial_admin`
  - `workspace_secret.hash`
  - `agents/`
- `<runtime_root>/connectors/discord/status.json`
- `<runtime_root>/connectors/discord/bindings.json`
- `<runtime_root>/connectors/discord/binding_audit.jsonl`
- `<runtime_root>/voice_config.json`
- `<runtime_root>/audio/<timestamp>_<agent>.mp3` (TTS output, auto-cleaned)
- `<runtime_root>/voice_sessions/<agent>.json`

Notes:

- Discord connector runtime files (`.gate/runtime/discord/status.json`,
  `bindings.json`, `binding_audit.jsonl`) are now read and written by the
  in-process gateway (`lib/server/server_discord_in_process_gateway.{ml,mli}`
  + `lib/gate/channel_gate_discord_state.{ml,mli}`) after RFC-0203 §Phase 3
  (#19393) deleted the external `sidecars/discord-bot/`. Path resolution is
  unchanged; the consumer just moved into the same server process. Operator
  setup: set `DISCORD_BOT_TOKEN` in the server's env and restart. See
  `docs/CONNECTOR-CONFIG-SCHEMA.md` §Discord.
- All voice paths resolve relative to `MASC_BASE_PATH/.masc/`.
  `voice_config.json` is discovered at `<runtime_root>/voice_config.json`
  where `<runtime_root>` = `MASC_BASE_PATH/.masc/`.
- `session.endpoints` in `voice_config.json` may be empty (`[]`).
  HTTP TTS (e.g. ElevenLabs direct) works without a session endpoint.
  Only Voice MCP session management requires a session endpoint.

### 3.8 Legacy / Compat Execution Artifacts

- `<runtime_root>/team-sessions/<session_id>/`
  - `session.json`
  - `events.jsonl`
  - `report.md`
  - `report.json`
  - `proof.md`
  - `proof.json`
  - `checkpoints/`
  - `worker-runs/`
  - `workers/`
- `<runtime_root>/local-workers/`
- `<runtime_root>/oas-runtime/`
- `<runtime_root>/archive/team-sessions/`

These still exist because some execution and proof surfaces have not been fully migrated away from them. They should not be treated as the main product-level operator concept.

## 4. Current Host Audit (2026-05-17)

Current observed state on the inspected host:

- Live server process:
  - `/Users/dancer/me/workspace/yousleepwhen/masc/_build/default/bin/main_eio.exe --host=127.0.0.1 --port=8935 --base-path=/Users/dancer/me`
- Effective base path:
  - `/Users/dancer/me`
- Effective runtime root:
  - `/Users/dancer/me/.masc`
- Effective config root:
  - `/Users/dancer/me/.masc/config`
  - Reason: live `/health` reports `startup.config_resolution.config_root.path` as `/Users/dancer/me/.masc/config`.
- Checked-in fallback/default config tree:
  - `/Users/dancer/me/workspace/yousleepwhen/masc/config`
- Both of these trees exist at the same time:
  - `/Users/dancer/me/.masc/*`
  - `/Users/dancer/me/.masc/.masc/*`

Interpretation:

- `/Users/dancer/me/.masc` is the current canonical runtime root for base path `/Users/dancer/me`; do not shorten this to `~/.masc`, which means `/Users/dancer/.masc` in a shell.
- `/Users/dancer/me/.masc/.masc` should be treated as historical drift from earlier runs that used `/Users/dancer/me/.masc` itself as `base_path`.
- The active config root should be treated as the resolved runtime config root under `/Users/dancer/me/.masc/config` unless `MASC_CONFIG_DIR` explicitly points elsewhere.
- The checked-in repo `config/` tree is the versioned default/seed source, not the live runtime truth by itself.

Current host definitely has live filesystem data for:

- tasks and backlog
- board
- goals
- Gate approvals and rules
- keepers
- command-plane and operator
- auth
- voice
- logs and traces

Current log sink observed today:

- `/Users/dancer/me/.masc/logs`
- current file-sink date: `2026-05-17`

[근거]

- `curl -fsS http://127.0.0.1:8935/health`; 확인일시: 2026-05-17 Asia/Seoul; 신뢰도: High
- `pgrep -fl main_eio`; 확인일시: 2026-05-17 Asia/Seoul; 신뢰도: High
- `test -f /Users/dancer/me/.masc/config/runtime.toml`; 확인일시: 2026-05-17 Asia/Seoul; 신뢰도: High

## 5. Operator Checklist for Root Drift

1. Pick one base-path convention per environment and stick to it.
   - `--base-path /Users/dancer/me` produces `/Users/dancer/me/.masc`
   - `--base-path /Users/dancer/me/.masc` normalizes to `/Users/dancer/me` and warns
   - Avoid bare `~/.masc` in docs and runbooks; write `<base-path>/.masc` or the fully resolved path.
2. Pick one active config root.
   - If `MASC_CONFIG_DIR` is set, that wins.
   - If you want the base-path config root to become active, unset `MASC_CONFIG_DIR` and restart.
   - Do not create a second operator config surface; the resolver only consults the active config root.
3. Treat `<base-path>/planning/` as a separate backup and cleanup lane from `.masc/`.
4. Do not delete a nested `.masc/.masc` tree until you have checked whether it still contains needed logs, traces, or backlog state.
5. When debugging keeper shell, clone, or PR-submit behavior, inspect these paths first:
   - `<runtime_root>/playground/<keeper>/repos/`
   - `<runtime_root>/keepers/<name>/`
   - `<runtime_root>/traces/`
   - `<active config root>/runtime.toml`

## Appendix A. Centralized Environment Inventory

This appendix lists the environment variables declared in the centralized config modules. Not all of them are required at boot; many are runtime tuning knobs.

### A.1 `env_config_core`

Used for base path, config discovery, bind/auth, storage backend, logging, and build identity.

```text
DUNE_SOURCEROOT
HOME
MASC_ADMIN_TOKEN
MASC_ASSETS_DIR
MASC_BASE_PATH
MASC_BUILD_GIT_COMMIT
MASC_CLUSTER_NAME
MASC_CONFIG_DIR
MASC_GOVERNANCE_LEVEL
MASC_HOST
MASC_HTTP_BASE_URL
MASC_HTTP_PORT
MASC_LOG_LEVEL
MASC_LOG_ROUTINE_LEVEL
MASC_PARSE_WARN
MASC_PERSONAS_DIR
MASC_PUBSUB_MAX_MESSAGES
MASC_TELEMETRY_ENABLED
MASC_WORKSPACE_ROOT
```

### A.2 `env_config_runtime`

Used for timeouts, cleanup intervals, transports, local model runtimes, board backend, worker runtime, web search, dashboard thresholds, and local execution behavior.

```text
LLAMA_DEFAULT_MODEL
LLAMA_SERVER_URL
LLAMA_SWARM_MODEL
MASC_AGENT_RATE_BURST
MASC_AGENT_RATE_LIMIT
MASC_AGENT_TRANSPORT
MASC_BOARD_BACKEND
MASC_BOARD_FLUSH_INTERVAL_SEC
MASC_BRIEFING_CACHE_TTL_SEC
MASC_CACHE_MAX_ENTRIES
MASC_CACHE_MAX_ENTRY_SIZE
MASC_CANCELLATION_CLEANUP_SEC
MASC_CANCELLATION_TOKEN_MAX_AGE_SEC
MASC_CLAIM_TTL_SECONDS
MASC_CLI_AGENT
MASC_CP_CLEANUP_DAYS
MASC_DASHBOARD_CTX_COMPACTING
MASC_DASHBOARD_CTX_HANDOFF_IMMINENT
MASC_DASHBOARD_CTX_PREPARING
MASC_DASHBOARD_KEEPER_ACTION_STALE_SEC
MASC_DASHBOARD_SIGNAL_LIVE_SEC
MASC_DASHBOARD_SIGNAL_QUIET_SEC
MASC_DASHBOARD_SIGNAL_STALE_SEC
MASC_DECISION_TTL_SEC
MASC_DISPATCH_V2
MASC_GRPC_ENABLED
MASC_GRPC_PORT
MASC_GRPC_TARGET
MASC_HTTP_AUTH_STRICT
MASC_KEEPER_BOOTSTRAP_WINDOW_SEC
MASC_KEEPER_ZOMBIE_THRESHOLD_SEC
MASC_LABEL_QUIET_THRESHOLD_SEC
MASC_LIST_PAGE_SIZE
MASC_LLAMA_MAX_TOKENS
MASC_LOCAL_MAX_TOKENS
MASC_LOCAL_RUNTIME_COOLDOWN_SEC
MASC_LOCAL_RUNTIME_DEBUG
MASC_LOCAL_WORKER_HEARTBEAT_SEC
MASC_LOCK_EXPIRY_WARNING_SEC
MASC_LOCK_TIMEOUT_SEC
MASC_URL
MASC_MESSAGE_MAX_COUNT
MASC_METRICS_FLUSH_SEC
MASC_OAS_SSE_DRAIN_INTERVAL_SEC
MASC_ORCHESTRATOR_AGENT
MASC_ORCHESTRATOR_ENABLED
MASC_ORCHESTRATOR_INTERVAL
MASC_ORCHESTRATOR_MIN_PRIORITY
MASC_ORCHESTRATOR_TIMEOUT
MASC_PROVIDER_RUN_TTL_SEC
MASC_PUBLIC_TOOLS_EXTRA
MASC_RATE_BURST
MASC_RATE_LIMIT
MASC_SESSION_LIVE_TURN_WINDOW_SEC
MASC_SESSION_MAX_AGE_SEC
MASC_SESSION_RATE_LIMIT_WINDOW_SEC
MASC_SPAWN_CODING_TIMEOUT_SEC
MASC_SPAWN_GRACE_PERIOD_SEC
MASC_SPAWN_TIMEOUT_SEC
MASC_SSE_BUFFER_TTL_SEC
MASC_STALLED_SESSION_THRESHOLD_SEC
MASC_STARTUP_WATCHDOG_SEC
MASC_TEAM_SESSION_MODEL_27B
MASC_TEAM_SESSION_MODEL_35B
MASC_TEAM_SESSION_MODEL_9B
MASC_TEAM_SESSION_ROUTER_CONFIDENCE_THRESHOLD
MASC_TEAM_SESSION_ROUTER_JUDGE
MASC_TEAM_SESSION_ROUTER_JUDGE_MODEL
MASC_TEAM_SESSION_ROUTER_JUDGE_TIMEOUT_SEC
MASC_TEMPO_DEFAULT_INTERVAL_SEC
MASC_TEMPO_MAX_INTERVAL_SEC
MASC_TEMPO_MIN_INTERVAL_SEC
MASC_TIMEOUT_GCLOUD_AUTH_SEC
MASC_TOOL_DESCRIPTION_BUDGET
MASC_USE_H2
MASC_WEB_SEARCH_CACHE_TTL_SEC
MASC_WEB_SEARCH_FALLBACKS
MASC_WEB_SEARCH_PROVIDER
MASC_WEB_SEARCH_PROVIDER_ORDER
MASC_WEB_SEARCH_RATE_LIMIT_MAX_CALLS
MASC_WEB_SEARCH_RATE_LIMIT_WINDOW_SEC
MASC_WEB_SEARCH_TIMEOUT_SEC
MASC_WEBRTC_ENABLED
MASC_WS_ENABLED
MASC_WS_PORT
MASC_ZOMBIE_CLEANUP_INTERVAL_SEC
MASC_ZOMBIE_THRESHOLD_SEC
OLLAMA_DEFAULT_MODEL
OLLAMA_SERVER_URL
ZAI_BASE_URL
```

### A.3 `env_config_keeper`

Used for explicit Keeper runtime configuration and observation cadence. The
generated [runtime tunables catalog](./runtime-tunables.md) is the field-level
SSOT; this inventory intentionally does not duplicate a hand-maintained list.

## Appendix B. Non-centralized Environment Reads

Centralized `env_config_*` modules are not the whole story yet. A repo-wide scan still finds additional `MASC_*` reads outside those files.

Important operator-facing families still outside the centralized inventory:

- dashboard and operator HTTP surfaces: `MASC_DASHBOARD_*`, `MASC_OPERATOR_*`, `MASC_WARM_DELAY_*`
- advanced keeper tuning: extra `MASC_KEEPER_*` reads from `keeper_config.ml`, `keeper_memory_bank.ml`, `keeper_tool_affinity.ml`, and related files
- transport edge cases: `MASC_FORCE_JSON_RESPONSE`, `MASC_POST_SSE_KEEPALIVE_SEC`, `MASC_SSE_*`
- worker runtime and Docker lanes: `MASC_WORKER_RUNTIME_*`
- goal, swarm, economy, and notify lanes: `MASC_GOAL_*`, `MASC_SWARM_*`, `MASC_ECONOMY_*`, `MASC_NOTIFY_*`
- connector overrides: `MASC_DISCORD_*`

To regenerate the inventories:

```bash
rg -oN '"MASC_[A-Z0-9_]+"' lib/config/env_config_core.ml lib/config/env_config_runtime.ml lib/config/env_config_keeper.ml | tr -d '"' | sort -u
rg -oN '"MASC_[A-Z0-9_]+"' lib bin | tr -d '"' | sort -u
rg -oN '"(LLAMA_[A-Z0-9_]+|OLLAMA_[A-Z0-9_]+|HOME|DUNE_SOURCEROOT)"' lib bin | tr -d '"' | sort -u
```
