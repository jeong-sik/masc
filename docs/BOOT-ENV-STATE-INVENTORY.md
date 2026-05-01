---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/config/
  - lib/config/env_config.mli
  - start-masc-mcp.sh
---

# Boot, Path, and Runtime State Inventory

This document answers four operator questions:

- Which environment inputs and startup flags affect boot.
- Which path rules decide the active runtime root and config root.
- Where live state, logs, and audit artifacts land on disk.
- What the current host is actually using right now.

For day-to-day active-root and init diagnosis, prefer
[`CONFIG-DOCTOR.md`](./CONFIG-DOCTOR.md). This document is the deeper inventory
behind that operator flow.

Scope:

- Canonical behavior in this document is derived from code.
- "Current host audit" is a dated snapshot of the machine inspected on 2026-04-09.
- Primary runtime domains are `tasks`, `board`, `goals`, `governance`, `autoresearch`, and `keepers`.
- `team-sessions`, `local-workers`, `oas-runtime`, and `command-plane` are documented only as compatibility, historical, or execution-artifact lanes, not as the primary product concept.

## 1. Boot Inputs and Precedence

### 1.1 Inputs that decide roots and boot behavior

| Input | What it controls | Used by |
| --- | --- | --- |
| `--base-path` | Startup runtime root selection. `main_eio` exports this to `MASC_BASE_PATH`. | `bin/main_eio.ml`, all `.masc` path helpers |
| `MASC_BASE_PATH` | Runtime base path once the server is running. `.masc` lives under this directory. | `Env_config_core`, `Room_utils`, keeper/board/control-plane/logging paths |
| `MASC_CONFIG_DIR` | Explicit config root override. Highest-precedence config selector. | `Config_dir_resolver`, bootstrap, keeper/persona config resolution |
| `MASC_PERSONAS_DIR` | Explicit personas root override. | `Config_dir_resolver`, keeper/persona loading |
| `MASC_STORAGE_TYPE` | Runtime backend selector. Only `filesystem` is active; PostgreSQL backend was removed. | bootstrap and backend setup |
| `HOME` | Fallback for home-level config discovery. | `Config_dir_resolver`, some artifact stores |
| `MASC_WORKSPACE_ROOT`, `ME_ROOT`, `DUNE_SOURCEROOT` | Workspace discovery, legacy repo fallback, some knowledge paths, `scripts/sb` resolution. | `Env_config_core`, `autoresearch_knowledge`, legacy paths |
| `MASC_HOST`, `MASC_HTTP_PORT`, `MASC_HTTP_BASE_URL` | Bind address and derived HTTP endpoint identity. | HTTP/bootstrap/provider routing |
| `MASC_ADMIN_TOKEN` | Privileged endpoint auth. | server auth |
| `MASC_POSTGRES_URL`, `MASC_PG_POOL_SIZE` | Postgres backend and pool configuration. | backend bootstrap and storage |

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
3. `~/.masc/config`
4. `cwd/config` when `MASC_ALLOW_REPO_CONFIG_FALLBACK=true`
5. executable-relative `config/` when `MASC_ALLOW_REPO_CONFIG_FALLBACK=true`

Important boot behavior:

- If `MASC_CONFIG_DIR` is unset, bootstrap initializes `<MASC_BASE_PATH>/.masc/config`.
- Bootstrap copies only missing files from the versioned `config/` tree; it does not overwrite an existing file.
- Supported launchers and `main_eio.exe doctor` should be read with a simpler operator contract:
  active config is `MASC_CONFIG_DIR` when set, otherwise `<MASC_BASE_PATH>/.masc/config`.
- This means a passive base-path config root can exist on disk even when it is not the active config root.

### 1.3 Personas root resolution

Canonical personas-root precedence is:

1. `MASC_PERSONAS_DIR`
2. `<resolved CONFIG_ROOT>/personas`

Keeper bootstrap may also source keeper defaults from `CONFIG_ROOT/keepers/<name>.toml`, even when personas are resolved from the personas tree.

### 1.4 What the config root contains

The checked-in versioned seed config tree currently contains:

| Path | Purpose |
| --- | --- |
| `config/cascade.json` | Provider/model cascade and routing defaults. |
| `config/tool_policy.toml` | Tool preset policy and allow/deny rules. |
| `config/keepers/*.toml` | Keeper defaults and policy-overridable profiles. |
| `config/personas/*` | Persona definitions and persona-specific profile data. |
| `config/prompts/*.md` | Versioned system prompt fragments and governance/keeper prompt templates. |
| `config/excuse_patterns.json` | Auxiliary config used by selected flows. |

`keeper_runtime.toml` is not checked into the repo seed tree. It is an optional
active-root file at `<active config root>/keeper_runtime.toml`.

### 1.3 keeper_runtime.toml — per-base-path startup keeper env seeding

All live startup-scoped `MASC_KEEPER_*` keeper runtime variables wired through
`Env_config_keeper` / `Keeper_config` can be set declaratively in
`<active config root>/keeper_runtime.toml`. The TOML file is loaded at server
startup by `Keeper_runtime_config.load_and_apply` (called from
`server_runtime_bootstrap.ml`) before any module that reads these env
vars initializes.

Operational contract:

- This file is `boot_static`, not hot-reloaded.
- The file seeds a process-local boot override store.
- Live tuning belongs in `Runtime_params`, not in parent-shell env edits.

**Precedence** (highest first):
1. Process env var (caller/CI override — never overwritten by TOML)
2. TOML value from `keeper_runtime.toml`
3. Hardcoded default in `Env_config_keeper` / `Keeper_keepalive`

Missing file is not an error (returns 0 overrides, uses env/defaults).
Parse errors log a warning and fall back to env defaults.

Legacy compatibility names that are no longer read by the unified turn path
are intentionally excluded from this TOML surface.

**Sections** (69 knobs total):

| Section | Count | Key examples |
| --- | --- | --- |
| `[bootstrap]` | 5 | `enabled`, `max_active_keepers`, `autoboot_max` |
| `[autonomous]` | 6 | `max_turns_per_call`, `semaphore_wait_timeout_sec`, `concurrency` |
| `[reactive]` | 2 | `max_turns_per_call`, `max_idle_turns` |
| `[heartbeat]` | 7 | `interval_sec`, `max_silence_sec`, `smart_heartbeat` |
| `[turn]` | 17 | `timeout_sec`, `stream_idle_timeout_sec`, `tool_cost_max_usd`, `temperature` |
| `[watchdog]` | 4 | `stale_sec`, `grace_sec`, `noop_threshold` |
| `[supervisor]` | 4 | `max_restarts`, `backoff_base_sec`, `backoff_max_sec` |
| `[lifecycle]` | 4 | `self_preservation_ratio`, `dead_ttl_sec` |
| `[budget]` | 1 | `daily_usd` |
| `[metrics]` | 2 | `max_bytes`, `max_rotated` |
| `[alert]` | 16 | `slack_enabled`, `slack_dm_user_id`, `github_enabled` |
| `[debug]` | 1 | `enabled` |

**Example** (`<active config root>/keeper_runtime.toml`):

```toml
[autonomous]
max_turns_per_call = 7           # default: 2
semaphore_wait_timeout_sec = 150 # default: 60

[reactive]
max_turns_per_call = 15

[bootstrap]
max_active_keepers = 12

[turn]
stream_idle_timeout_sec = 120
tool_cost_max_usd = 1.25
max_tools_per_turn = 64
llm_rerank = true

[watchdog]
stale_sec = 600
grace_sec = 900
```

`tool_cost_max_usd = 0` means unlimited and disables the keeper cost gate.

**Implementation**: `lib/keeper/keeper_runtime_config.ml` maintains a
`key_to_env` table mapping TOML dotted keys to env var names. Values
are recorded in a process-local boot override store so existing
`Env_config_*` and keeper helpers can resolve TOML-backed defaults
without mutating the parent environment.

## 2. Canonical Root and Path Resolution

### 2.1 Root formulas

- Default cluster runtime root: `<base_path>/.masc`
- When no explicit `base_path` is provided, runtime state falls back to `~/.masc`
  by treating `HOME` as the implicit base path.
- Named cluster runtime root: `<base_path>/.masc/clusters/<cluster_name>`
- Config root: resolved separately by the precedence chain above
- Personas root: resolved separately from the config root
- Planning root: `<base_path>/planning/<task_id>` (important outlier: not inside `.masc`)

### 2.2 Path matrix

| Artifact lane | Canonical path |
| --- | --- |
| Runtime root | `<base_path>/.masc` |
| Cluster root | `<base_path>/.masc/clusters/<cluster_name>` |
| Base-path config root | `<base_path>/.masc/config` |
| Keepers | `<runtime_root>/keepers` |
| Traces | `<runtime_root>/traces` |
| Playground | `<runtime_root>/playground/<keeper>/...` |
| Tasks/backlog | `<runtime_root>/tasks/backlog.json` |
| Task archive | `<runtime_root>/tasks-archive.json` |
| Agents | `<runtime_root>/agents` |
| Messages | `<runtime_root>/messages` |
| Current task pointer | `<runtime_root>/current_task` |
| Planning context | `<base_path>/planning/<task_id>/` |
| Runs | `<runtime_root>/runs/<task_id>/` |
| Board | `<runtime_root>/board_posts.jsonl`, `board_comments.jsonl`, `board_votes.jsonl` |
| Goals | `<runtime_root>/goals.json`, `goals_snapshots/`, `goals_scheduler_state.json` |
| Governance | `<runtime_root>/governance.json`, `governance_v2/...` |
| Autoresearch loops | `<runtime_root>/autoresearch/<loop_id>/` |
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
- `<runtime_root>/messages/`: room and broadcast message artifacts.
- `<runtime_root>/current_task`: planning pointer for the current claimed task.
- `<base_path>/planning/<task_id>/`: planning-with-files context:
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

Important outlier: planning data does not live under `.masc`; it lives under `<base_path>/planning/`.

### 3.2 Board

- `<runtime_root>/board_posts.jsonl`
- `<runtime_root>/board_comments.jsonl`
- `<runtime_root>/board_votes.jsonl`
- `<runtime_root>/mention_inbox.jsonl`

Notes:

- JSONL is the board backend. PostgreSQL board backend was removed; filesystem is the only supported lane.

### 3.3 Goals

- `<runtime_root>/goals.json`
- `<runtime_root>/goals_snapshots/`
- `<runtime_root>/goals_scheduler_state.json`

Goal dispatch and long/mid/short-horizon behavior also depend on model-routing config and goal-related environment settings.

### 3.4 Governance

- `<runtime_root>/governance.json`
- `<runtime_root>/mcp-sessions.json`
- `<runtime_root>/governance_v2/cases/`
- `<runtime_root>/governance_v2/execution_orders/`
- `<runtime_root>/governance_v2/rulings/`
- `<runtime_root>/audit-approvals/YYYY-MM/DD.jsonl`

Compatibility note:

- `governance_v2/petitions/` may still exist on disk, but petition-first governance is no longer the primary operating concept.
- Some older governance reads still inspect `<runtime_root>/governance/judgments/`.

### 3.5 Autoresearch

- `<runtime_root>/autoresearch/<loop_id>/`
  - `results.jsonl`
  - `state.json`
  - `swarm.json`
  - `worktree/`
- `<me_root>/.masc/autoresearch/findings/findings.jsonl`

Important outlier:

- The findings store is resolved from `ME_ROOT` or `HOME`, not from the room-config runtime root.
- Legacy links from team-session artifacts to autoresearch loops may still exist.

### 3.6 Keepers

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

### 3.7 Command Plane and Operator

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

### 3.8 Logs, Audit, Metrics, and Tool Traces

- `<runtime_root>/logs/`: service logs.
- `<runtime_root>/audit/YYYY-MM/DD.jsonl` and legacy `<runtime_root>/audit.jsonl`
- `<runtime_root>/tool_calls/YYYY-MM/DD.jsonl`
- `<runtime_root>/tool_usage/YYYY-MM/DD.jsonl`
- `<runtime_root>/runtime_params.json`
- `<runtime_root>/param_audit.jsonl`
- `<runtime_root>/metrics/<agent>/YYYY-MM.jsonl`
- `<runtime_root>/heuristic_metrics.jsonl`
- `<runtime_root>/drift_guard.jsonl`
- `<runtime_root>/costs.jsonl`
- `<runtime_root>/autonomy_stats.jsonl`

Current host note:

- The inspected host also contains auxiliary event and telemetry lanes such as `activity-events/`, `events/`, `telemetry/`, and `data/tool-metrics/`.
- Repo-local `masc-mcp/logs/` directories are non-canonical historical or
  harness captures. Live runtime service logs belong under `<runtime_root>/logs/`.

### 3.9 Auth, Connectors, and Voice

- `<runtime_root>/auth/`
  - `config.json`
  - `initial_admin`
  - `room_secret.hash`
  - `agents/`
- `<runtime_root>/connectors/discord/status.json`
- `<runtime_root>/connectors/discord/bindings.json`
- `<runtime_root>/connectors/discord/binding_audit.jsonl`
- `<runtime_root>/voice_config.json`
- `<runtime_root>/audio/<timestamp>_<agent>.mp3` (TTS output, auto-cleaned)
- `<runtime_root>/voice_sessions/<agent>.json`

Notes:

- Discord connector runtime files are shared between the gate server and the
  Discord bot. When the bot uses relative paths, resolve them against the same
  `MASC_BASE_PATH` as the server. Operational setup and verification steps live
  in `sidecars/discord-bot/README.md`.
- `VOICE_MCP_HOST` and `VOICE_MCP_PORT` remain legacy environment fallbacks.
- All voice paths resolve relative to `MASC_BASE_PATH/.masc/`.
  `voice_config.json` is discovered at `<runtime_root>/voice_config.json`
  where `<runtime_root>` = `MASC_BASE_PATH/.masc/`.
- `session.endpoints` in `voice_config.json` may be empty (`[]`).
  HTTP TTS (e.g. ElevenLabs direct) works without a session endpoint.
  Only Voice MCP session management requires a session endpoint.

### 3.10 Legacy / Compat Execution Artifacts

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

## 4. Current Host Audit (2026-04-09)

Current observed state on the inspected host:

- Live server process:
  - `/Users/dancer/me/workspace/yousleepwhen/masc-mcp/_build/default/bin/main_eio.exe --host=127.0.0.1 --port=8935 --base-path=/Users/dancer/me`
- Effective base path:
  - `/Users/dancer/me`
- Effective runtime root:
  - `/Users/dancer/me/.masc`
- Effective config root:
  - `/Users/dancer/me/.masc/config`
  - Reason: for the normal `--base-path=/Users/dancer/me` runtime without an explicit `MASC_CONFIG_DIR` override, config resolves under the base path.
- Checked-in fallback/default config tree:
  - `/Users/dancer/me/workspace/yousleepwhen/masc-mcp/config`
- Home fallback config root is absent on this host right now:
  - `/Users/dancer/.masc/config` does not exist.
- Both of these trees exist at the same time:
  - `/Users/dancer/me/.masc/*`
  - `/Users/dancer/me/.masc/.masc/*`

Interpretation:

- `/Users/dancer/me/.masc` is the current canonical runtime root.
- `/Users/dancer/me/.masc/.masc` should be treated as historical drift from earlier runs that used `/Users/dancer/me/.masc` itself as `base_path`.
- The active config root should be treated as the resolved runtime config root under `/Users/dancer/me/.masc/config` unless `MASC_CONFIG_DIR` explicitly points elsewhere.
- The checked-in repo `config/` tree is the versioned default/fallback source, not the live runtime truth by itself.

Current host definitely has live filesystem data for:

- tasks and backlog
- board
- goals
- governance
- autoresearch
- keepers
- command-plane and operator
- auth
- voice
- logs and traces

Current log sink observed today:

- `/Users/dancer/me/.masc/logs/masc-server.log`
- `/Users/dancer/me/.masc/logs/system_log_2026-04-09.jsonl`

[근거]

- `ps aux | rg 'main_eio\.exe --host=127.0.0.1 --port=8935 --base-path=/Users/dancer/me'`; 확인일시: 2026-04-09 Asia/Seoul; 신뢰도: High
- `ps eww -p 3568` with secret-bearing values redacted; 확인일시: 2026-04-09 Asia/Seoul; 신뢰도: High
- `env | sort | rg '^(HOME|ME_ROOT|MASC_BASE_PATH|MASC_CONFIG_DIR|MASC_PERSONAS_DIR)='`; 확인일시: 2026-04-09 Asia/Seoul; 신뢰도: High
- `find /Users/dancer/me/.masc ...`; 확인일시: 2026-04-09 Asia/Seoul; 신뢰도: High
- `test -d /Users/dancer/.masc/config && echo present || echo absent`; 확인일시: 2026-04-09 Asia/Seoul; 신뢰도: High

## 5. Operator Checklist for Root Drift

1. Pick one base-path convention per environment and stick to it.
   - `--base-path /Users/dancer/me` produces `/Users/dancer/me/.masc`
   - `--base-path /Users/dancer/me/.masc` normalizes to `/Users/dancer/me` and warns
2. Pick one active config root.
   - If `MASC_CONFIG_DIR` is set, that wins.
   - If you want the base-path config root to become active, unset `MASC_CONFIG_DIR` and restart.
   - The home fallback is only relevant when both of the above fail and `~/.masc/config` actually exists.
3. Treat `<base_path>/planning/` as a separate backup and cleanup lane from `.masc/`.
4. Do not delete a nested `.masc/.masc` tree until you have checked whether it still contains needed logs, traces, or backlog state.
5. When debugging keeper shell, clone, or PR-submit behavior, inspect these paths first:
   - `<runtime_root>/playground/<keeper>/repos/`
   - `<runtime_root>/keepers/<name>/`
   - `<runtime_root>/traces/`
   - `<active config root>/tool_policy.toml`
   - `<active config root>/cascade.json`

## Appendix A. Centralized Environment Inventory

This appendix lists the environment variables declared in the centralized config modules. Not all of them are required at boot; many are runtime tuning knobs.

### A.1 `env_config_core`

Used for base path, config discovery, bind/auth, storage backend, logging, and build identity.

```text
DUNE_SOURCEROOT
HOME
MASC_ADMIN_TOKEN
MASC_ASSETS_DIR
MASC_AUTO_RESPOND
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
MASC_PG_POOL_SIZE
MASC_POSTGRES_URL
MASC_PUBSUB_MAX_MESSAGES
MASC_RELAY_CALIBRATION_ENABLED
MASC_STORAGE_TYPE
MASC_TELEMETRY_ENABLED
MASC_TOOL_AUTH_STRICT
MASC_WORKSPACE_ROOT
ME_ROOT
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
MASC_CDAL_ENABLED
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
MASC_FULL_SURFACE
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
MASC_LOCAL_WORKER_MAX_TOKENS
MASC_LOCK_EXPIRY_WARNING_SEC
MASC_LOCK_TIMEOUT_SEC
MASC_MCP_URL
MASC_MEMORY_OAS_DEFAULT_IMPORTANCE
MASC_MESSAGE_MAX_COUNT
MASC_METRICS_FLUSH_SEC
MASC_OAS_SSE_DRAIN_INTERVAL_SEC
MASC_OPENAI_COMPAT
MASC_ORCHESTRATOR_AGENT
MASC_ORCHESTRATOR_ENABLED
MASC_ORCHESTRATOR_INTERVAL
MASC_ORCHESTRATOR_MIN_PRIORITY
MASC_ORCHESTRATOR_TIMEOUT
MASC_PROC_MIN_CONFIDENCE
MASC_PROC_MIN_EVIDENCE
MASC_PROVIDER_RUN_TTL_SEC
MASC_PUBLIC_TOOLS_EXTRA
MASC_PULSE_MAX_CONSUMER_FAILURES
MASC_RATE_BURST
MASC_RATE_LIMIT
MASC_RELAY_TARGET_AGENT
MASC_SESSION_LIVE_TURN_WINDOW_SEC
MASC_SESSION_MAX_AGE_SEC
MASC_SESSION_RATE_LIMIT_WINDOW_SEC
MASC_SLOT_YIELD_ENABLED
MASC_SMART_HB_BASE_INTERVAL_SEC
MASC_SMART_HB_IDLE_MULTIPLIER
MASC_SMART_HB_IDLE_THRESHOLD_SEC
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
MASC_TOOL_READONLY_RETRY_LIMIT
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
VOICE_MCP_HOST
VOICE_MCP_PORT
ZAI_BASE_URL
```

### A.3 `env_config_governance`

Used for inference cache, autonomy, operator judge, dashboard governance judge, and default routing/model selection.

```text
MASC_AUTONOMY_MAX_STARVATION_TICKS
MASC_AUTONOMY_QUIET_END
MASC_AUTONOMY_QUIET_START
MASC_AUTONOMY_STARVATION_BONUS_COEF
MASC_AUTONOMY_THOMPSON_WEIGHT
MASC_AUTONOMY_VOTE_DECAY_FACTOR
MASC_DASHBOARD_FIXTURE
MASC_DASHBOARD_FIXTURES_ENABLED
MASC_DASHBOARD_GOVERNANCE_JUDGE_ENABLED
MASC_DASHBOARD_GOVERNANCE_JUDGE_INTERVAL_SEC
MASC_DASHBOARD_GOVERNANCE_JUDGE_TIMEOUT_SEC
MASC_DEFAULT_CASCADE
MASC_DEFAULT_MODEL
MASC_DEFAULT_PROVIDER
MASC_EVENT_BUFFER_SIZE
MASC_GOAL_DISPATCH_RUNTIME
MASC_GOAL_MODELS
MASC_INFERENCE_CACHE_ENABLED
MASC_INFERENCE_CACHE_L1_MAX_ENTRIES
MASC_INFERENCE_CACHE_MAX_PROMPT_CHARS
MASC_INFERENCE_CACHE_MAX_TEMP
MASC_INFERENCE_CACHE_TTL_SEC
MASC_INFERENCE_TIMEOUT_SEC
MASC_NEO4J_TIMEOUT_SEC
MASC_OPERATOR_CACHE_TTL
MASC_OPERATOR_JUDGE_ENABLED
MASC_OPERATOR_JUDGE_INTERVAL_SEC
MASC_OPERATOR_JUDGE_ROOM_TTL_SEC
MASC_OPERATOR_JUDGE_SESSION_TTL_SEC
MASC_OPERATOR_JUDGE_TIMEOUT_SEC
MASC_RATE_LIMIT_CLEANUP_INTERVAL_SEC
MASC_RATE_LIMIT_ENTRY_MAX_AGE_SEC
MASC_ROUTING_CASCADE
MASC_SPAWN_CACHE_POLICY
MASC_SSE_KEEPALIVE_SEC
```

### A.4 `env_config_keeper`

Used for keeper bootstrap, alert fanout, supervisor policy, keepalive cadence, tool retry behavior, OAS turn limits, and context compaction thresholds.

```text
MASC_ALERT_DEDUP_WINDOW_SEC
MASC_COMPACT_ANCHOR_BOOST
MASC_COMPACT_DROP_THRESHOLD
MASC_COMPACT_DYN_FOCUSED_RATIO
MASC_COMPACT_DYN_MULTI_AGENT_RATIO
MASC_COMPACT_KEEP_RECENT
MASC_COMPACT_LARGE_CLOUD_FLOOR
MASC_COMPACT_ROLE_ASSISTANT
MASC_COMPACT_ROLE_SYSTEM
MASC_COMPACT_ROLE_TOOL
MASC_COMPACT_ROLE_USER
MASC_COMPACT_SMALL_LOCAL_FLOOR
MASC_COMPACT_TOOL_ABSENT
MASC_COMPACT_TOOL_PRESENT
MASC_COMPACT_TOOL_PRUNE_LIMIT
MASC_COMPACT_W_RECENCY
MASC_COMPACT_W_ROLE
MASC_COMPACT_W_TOOL
MASC_CONTEXT_RATIO_HARD_CAP
MASC_DASHBOARD_HEALTH_CTX_CRITICAL
MASC_DASHBOARD_HEALTH_CTX_WARN
MASC_DASHBOARD_HEALTH_PENALTY_CRITICAL
MASC_DASHBOARD_HEALTH_PENALTY_WARN
MASC_DASHBOARD_RUNTIME_WARNING_CTX_RATIO
MASC_KEEPER_ALERT_BOARD_AUTHOR
MASC_KEEPER_ALERT_BOARD_ENABLED
MASC_KEEPER_ALERT_BOARD_HEARTH
MASC_KEEPER_ALERT_BOARD_VISIBILITY
MASC_KEEPER_ALERT_ENABLED
MASC_KEEPER_ALERT_GITHUB_ENABLED
MASC_KEEPER_ALERT_GITHUB_LABEL
MASC_KEEPER_ALERT_GITHUB_MIN_SCORE
MASC_KEEPER_ALERT_GITHUB_REPO
MASC_KEEPER_ALERT_MAX_BODY_CHARS
MASC_KEEPER_ALERT_MAX_RETRIES
MASC_KEEPER_ALERT_MIN_SCORE
MASC_KEEPER_ALERT_RETRY_BASE_DELAY_MS
MASC_KEEPER_ALERT_SLACK_DM_ENABLED
MASC_KEEPER_ALERT_SLACK_DM_USER_ID
MASC_KEEPER_ALERT_SLACK_ENABLED
MASC_KEEPER_ALERT_SLACK_WEBHOOK_URL
MASC_KEEPER_BOARD_DEBOUNCE_SEC
MASC_KEEPER_BOOTSTRAP_ENABLED
MASC_KEEPER_BOOTSTRAP_MAX_ACTIVE_KEEPERS
MASC_KEEPER_BOOTSTRAP_MAX_SCAN
MASC_KEEPER_BOOTSTRAP_STALE_TURN_SEC
MASC_KEEPER_DEAD_TTL_SEC
MASC_KEEPER_DEBUG
MASC_KEEPER_DELIBERATION_DAILY_BUDGET_USD
MASC_KEEPER_GRPC_MAX_RECONNECT
MASC_KEEPER_GRPC_RECONNECT_BACKOFF_SEC
MASC_KEEPER_HEARTBEAT_INTERVAL_SEC
MASC_KEEPER_HEARTBEAT_JITTER_FACTOR
MASC_KEEPER_IDLE_SKIP_THRESHOLD
MASC_KEEPER_MAX_CONSECUTIVE_HB_FAILURES
MASC_KEEPER_MAX_CONSECUTIVE_TOOL_FAILURES
MASC_KEEPER_MAX_CONSECUTIVE_TURN_FAILURES
MASC_KEEPER_MAX_IDLE_TURNS_AUTONOMOUS
MASC_KEEPER_MAX_IDLE_TURNS_REACTIVE
MASC_KEEPER_MAX_SILENCE_SEC
MASC_KEEPER_METRICS_MAX_BYTES
MASC_KEEPER_METRICS_MAX_ROTATED
MASC_KEEPER_OAS_MAX_TURNS_PER_CALL
MASC_KEEPER_OAS_TIMEOUT_SEC
MASC_KEEPER_PAUSED_CLEANUP_TTL_SEC
MASC_KEEPER_PROACTIVE_MAX_ATTEMPTS
MASC_KEEPER_REDUCER_CAP_TOKENS
MASC_KEEPER_REDUCER_KEEP_RECENT
MASC_KEEPER_SELF_PRESERVATION_MIN_CANDIDATES
MASC_KEEPER_SELF_PRESERVATION_RATIO
MASC_KEEPER_SLEEP_CHUNK_SEC
MASC_KEEPER_SMART_HEARTBEAT
MASC_KEEPER_SNAPSHOT_SEC
MASC_KEEPER_STAGE_TIMING_RING_SIZE
MASC_KEEPER_SUPERVISOR_BACKOFF_BASE_S
MASC_KEEPER_SUPERVISOR_BACKOFF_MAX_S
MASC_KEEPER_SUPERVISOR_MAX_RESTARTS
MASC_KEEPER_SUPERVISOR_SWEEP_SEC
MASC_KEEPER_TURN_TIMEOUT_SEC
MASC_KEEPER_WORK_AS_HEARTBEAT
```

## Appendix B. Non-centralized Environment Reads

Centralized `env_config_*` modules are not the whole story yet. A repo-wide scan still finds additional `MASC_*` reads outside those files.

Important operator-facing families still outside the centralized inventory:

- dashboard and operator HTTP surfaces: `MASC_DASHBOARD_*`, `MASC_OPERATOR_*`, `MASC_WARM_DELAY_*`
- advanced keeper tuning: extra `MASC_KEEPER_*` reads from `keeper_config.ml`, `keeper_memory_bank.ml`, `keeper_tool_affinity.ml`, and related files
- transport edge cases: `MASC_ALLOW_LEGACY_ACCEPT`, `MASC_FORCE_JSON_RESPONSE`, `MASC_POST_SSE_KEEPALIVE_SEC`, `MASC_SSE_*`
- worker runtime and Docker lanes: `MASC_WORKER_RUNTIME_*`
- goal, swarm, economy, and notify lanes: `MASC_GOAL_*`, `MASC_SWARM_*`, `MASC_ECONOMY_*`, `MASC_NOTIFY_*`
- connector overrides: `MASC_DISCORD_*`

To regenerate the inventories:

```bash
rg -oN '"MASC_[A-Z0-9_]+"' lib/config/env_config_core.ml lib/config/env_config_runtime.ml lib/config/env_config_governance.ml lib/config/env_config_keeper.ml | tr -d '"' | sort -u
rg -oN '"MASC_[A-Z0-9_]+"' lib bin | tr -d '"' | sort -u
rg -oN '"(LLAMA_[A-Z0-9_]+|OLLAMA_[A-Z0-9_]+|VOICE_MCP_[A-Z0-9_]+|ME_ROOT|HOME|DUNE_SOURCEROOT)"' lib bin | tr -d '"' | sort -u
```
