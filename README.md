# masc-mcp

[![OCaml](https://img.shields.io/badge/OCaml-5.4+-orange.svg)](https://ocaml.org/)
[![OAS](https://img.shields.io/badge/agent__sdk-%E2%89%A50.155.1-blue.svg)](https://github.com/jeong-sik/oas)

> Personal project. No production SLA, no external support, no compatibility guarantees. The API surface, schema, and dashboard change on the author's schedule.
>
> 개인 프로젝트입니다. 프로덕션 SLA, 외부 지원, 호환성 보증 없음. 사용 시 자기 책임. 자동 코딩 에이전트가 자기 자신의 좌표/턴/리소스를 다른 에이전트와 공유해야 하는 단일-기기 워크플로우를 위해 만들어진 도구.

Multi-agent coordination server on OCaml 5.x + Eio. Keeps several coding agents pointed at the same repository: shared namespace, task ownership, broadcasts, worktrees, a supervisor-visible audit surface, and OAS-backed keeper execution.

Designed for repo-local, single-machine, trusted-network workflows where multiple AI agents need shared coordination state instead of ad-hoc terminal coordination. It is not designed for hostile networks, multi-tenant SaaS, or unattended production duty.

Current surface map (what is exercised vs. what is experimental):

- Primary, exercised daily: repo coordination for coding workflows
- Runtime: OAS-backed keeper execution and operator-supervised delivery
- Supporting: dashboard, remote-safe operator visibility, keeper status
- Historical or retired: command-plane/team-session compatibility lanes, research modules, archived docs

"Primary" means it is what the author actually uses; it does not imply external production support.

Use `masc-mcp` when you need to reduce:

- file conflicts between agents
- duplicate implementation attempts
- stale context between parallel workers
- invisible ownership, heartbeat, and intervention state

Do not start with `masc-mcp` if you need:

- multi-tenant SaaS isolation
- a generic workflow scheduler
- a model-serving platform
- a stable promise for every merged experimental surface

## Architecture

```
┌──────────────────────────────────────────────────┐
│              Consumer / Client                    │
│       (Claude, Gemini, Codex, Local Agent)        │
└────────────────┬─────────────────────────────────┘
                 │  MCP (JSON-RPC)
┌────────────────▼─────────────────────────────────┐
│            MASC-MCP  (coordination)               │
│                                                   │
│  Room/Board  Keeper   Governance    Operator      │
│  Tasks                             Dashboard      │
│                                                   │
│         ┌── OAS bridges ──┐                       │
└─────────┤                 ├───────────────────────┘
          │                 │
┌─────────▼─────────────────▼──────────────────────┐
│         OAS / agent_sdk  (agent runtime)          │
│  Agent.run  Builder  Hooks  Checkpoint  Memory    │
│  Context_reducer  Tool_selector  Structured       │
└──────────────────────────────────────────────────┘
```

**MASC** decides when, why, and which provider/model chain to use. **OAS** handles single-agent execution, tool dispatch, context management, and the concrete single-provider request once MASC has selected it. MASC depends on OAS; OAS does not know about MASC.

### Transport

All protocols run concurrently from a single Eio fiber pool:

| Protocol | Default | Notes |
|----------|---------|-------|
| HTTP/1.1 + HTTP/2 | `:8935` | Primary MCP endpoint at `/mcp` |
| SSE | `:8935` | Unlimited streams per h2 connection |
| gRPC | `:8936` | Keeper queries and subscriptions |
| WebSocket | `:8937` | Standalone + discovery via `/ws` |
| WebRTC | `:8935` | Signaling endpoints `POST /webrtc/offer` and `POST /webrtc/answer` (gated by `Server_webrtc_transport.is_enabled`) |

### Tech Stack

- **OCaml 5.4+** with Eio structured concurrency (no Lwt)
- **agent_sdk** >= 0.155.1 (OAS agent runtime; pinned floor in `masc_mcp.opam` and `dune-project`)
- **mcp_protocol** >= 1.3.0 (MCP JSON-RPC contract)
- **h2-eio** (HTTP/2), **grpc-direct** (gRPC), **ocaml-webrtc** (WebRTC)
- **caqti** + PostgreSQL (optional), **sqlite3** (fallback), **neo4j_bolt** (optional graph)
- **opentelemetry** (OTLP tracing)

## Quick Start

### Install (prebuilt binary)

Supported: macOS arm64, Linux x86_64. Other platforms must build from source (see below).

```bash
curl -fsSL https://raw.githubusercontent.com/jeong-sik/masc-mcp/main/scripts/install.sh | bash
```

The installer:

- downloads the latest tagged binary from GitHub Releases into `~/.local/bin/masc-mcp`
- seeds the minimum config (`./.masc/config/tool_policy.toml`) needed for boot
- runs `--version` as a smoke check

Pin a version, change the install dir, or skip the config seed:

```bash
curl -fsSL https://raw.githubusercontent.com/jeong-sik/masc-mcp/main/scripts/install.sh \
  | bash -s -- --version v0.8.0 --prefix /usr/local/bin --base-path /path/to/project
```

`--dry-run` previews everything without writing. Full flag list: `install.sh --help`.

Start the server and check health:

```bash
masc-mcp --base-path "$PWD" --port 8935
curl http://127.0.0.1:8935/health
```

### Build from source

Use this if you need a platform without a release asset, an unreleased commit, or you
plan to develop on the codebase.

```bash
git clone https://github.com/jeong-sik/masc-mcp.git
cd masc-mcp

# Pin private dependencies (OAS, mcp_protocol, etc.)
scripts/opam-pin-external-deps.sh
opam install . --deps-only
dune build

scripts/run-local.sh --target-dir "$PWD"
PORT="$(scripts/run-local.sh --print-port --target-dir "$PWD")"
curl "http://127.0.0.1:${PORT}/health"
./_build/default/bin/main_eio.exe doctor --base-path "$PWD"
```

Defaults:

- local-dev HTTP / MCP port: `9100-9999` range, deterministically derived from the target path
- default bind host: `127.0.0.1`
- local-dev data root: `<target>/.masc/`
- local-dev config root: `<target>/.masc/config`
- local-dev personas root: `<target>/.masc/config/personas`
- local-dev transports: HTTP on, gRPC/WS/WebRTC off

Notes:

- Check the default port for a target: `scripts/run-local.sh --print-port --target-dir /path/to/project`
- To use a fixed port: `scripts/run-local.sh --target-dir /path/to/project --port 94xx`
- For shared repo/full-runtime paths, continue using `./start-masc-mcp.sh --http`
- For a full boot/path/state inventory, see [docs/BOOT-ENV-STATE-INVENTORY.md](docs/BOOT-ENV-STATE-INVENTORY.md)
- For active config/init diagnosis, use [docs/CONFIG-DOCTOR.md](docs/CONFIG-DOCTOR.md)

Other start modes:

| Mode | Command | Use case |
|------|---------|----------|
| Loopback | `scripts/start-loopback.sh` | Local dev, fixed port 8935, keepers off |
| Dir-local | `scripts/run-local.sh --target-dir /path` | Per-project isolation, auto port |
| Full runtime | `./start-masc-mcp.sh --http` | All transports, keeper autoboot, dashboard |
| Direct binary | `./_build/default/bin/main_eio.exe --port 8935 --base-path "$HOME"` | Manual control |

If you bind to a non-loopback address such as `0.0.0.0`, treat that as a remote exposure path and configure auth first. See [docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md) and [docs/spec/09-server-transport.md](docs/spec/09-server-transport.md).

## MCP Client Setup

```json
{
  "mcpServers": {
    "masc": {
      "type": "http",
      "url": "http://127.0.0.1:8935/mcp"
    }
  }
}
```

- `/mcp` — full coordination surface (local-first)
- `/mcp/operator` — bearer-token only, remote-safe reduced surface
- Full config templates: [docs/MCP-TEMPLATE.md](docs/MCP-TEMPLATE.md)
- For a dir-local local-dev environment, replace `8935` with the output of `scripts/run-local.sh --print-port --target-dir ...`

## Keeper System

Keepers are long-running autonomous agents that maintain repo continuity. They run as Eio fibers with heartbeat loops, checkpoint/resume, and supervised restart.

### Lifecycle

Keepers follow a 12-state deterministic state machine. The full state list is the source of truth in `lib/keeper/keeper_state_machine.mli` (`type state`):

```
Offline       Registered, no heartbeat fiber yet
Running       Healthy heartbeat loop
Failing       Consecutive failures, probing recovery
Overflowed    Provider context exceeded, auto-compact triggered
Compacting    Context compaction in progress
HandingOff    Generation rollover in progress
Draining      Graceful shutdown, finishing the current turn
Paused        Operator-paused or compact-retry exhausted
Stopped       Clean exit (terminal)
Crashed       Unrecoverable error, restart candidate
Restarting    Supervisor backoff before re-launch
Dead          Restart budget exhausted (terminal)
```

Schematically: `Offline → Running → {Failing | Overflowed | Compacting | HandingOff | Draining} → Paused / Stopped / Crashed → Restarting → Dead`. If the README ever drifts from `keeper_state_machine.mli`, trust the `.mli`.

### Autoboot

Keeper definitions live in `config/keepers/*.toml`. When `MASC_KEEPER_BOOTSTRAP_ENABLED=true`, the server discovers and starts all keepers on boot with staggered warmup delays.

### Turn Budget

Each keeper call to `Agent.run` is limited to `MASC_KEEPER_OAS_MAX_TURNS_PER_CALL` turns (default: 15). When exhausted, the keeper saves a checkpoint and resumes in the next heartbeat cycle. The keeper can call `extend_turns` to request more turns up to an absolute ceiling (200).

Adaptive OAS timeout: `base 180s + 1.5s per 1K context tokens`, capped at [30, 600]s.

### Key Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MASC_KEEPER_BOOTSTRAP_ENABLED` | `true` | Enable keeper autoboot |
| `MASC_KEEPER_HEARTBEAT_INTERVAL_SEC` | `30` | Heartbeat cadence (5-300s) |
| `MASC_KEEPER_OAS_MAX_TURNS_PER_CALL` | `15` | Turns per Agent.run call (1-50) |
| `MASC_KEEPER_OAS_TIMEOUT_SEC` | adaptive | Override OAS timeout (30-600s) |
| `MASC_KEEPER_TURN_TIMEOUT_SEC` | `1200` | Wall-clock turn guard (60-3600s) |
| `MASC_KEEPER_SUPERVISOR_MAX_RESTARTS` | `5` | Restart attempts before Dead |
| `MASC_KEEPER_IDLE_SKIP_THRESHOLD` | `4` | Consecutive idle calls before Skip |

Full list: `lib/config/env_config_keeper.ml`. Per-keeper config: `config/keepers/*.toml`.

Operator note:

- `repo/config` is the checked-in seed, not the live config root.
- The supported active root is `MASC_CONFIG_DIR` when set, otherwise `<base-path>/.masc/config`.
- Use `main_eio.exe doctor` before editing config if there is any doubt.

Reload contracts:

- env vars are a boot contract unless a runtime control plane says otherwise
- `config/keepers/*.toml` is reconciled on the next supervisor sweep
- `config/cascade.json` is applied on the next model resolve/turn
- `config/keeper_runtime.toml` and `config/tool_policy.toml` require restart

See [docs/ENV-CONTRACT.md](docs/ENV-CONTRACT.md) and
[docs/TOML-RELOAD-MATRIX.md](docs/TOML-RELOAD-MATRIX.md).

## Model Cascade

- `config/cascade.json` is a MASC runtime contract.
- MASC owns cascade schema, parsing, and selection policy; OAS only sees the resolved concrete provider/model choice passed per call.
- Each keeper can override the repo default via `cascade_name` in its TOML.
- For committed defaults, prefer explicit `provider:model_id` labels instead of convenience labels.
- Checked-in defaults must stay limited to providers that the currently pinned OAS runtime can actually execute once selected.
- See [docs/OAS-MASC-BOUNDARY.md](docs/OAS-MASC-BOUNDARY.md), [docs/spec/13-oas-integration.md](docs/spec/13-oas-integration.md), and [docs/spec/14-configuration.md](docs/spec/14-configuration.md).

## Safe Starting Paths

### 1. Repo Coordination

```text
masc_start(path="/your/project", task_title="My first task")
```

Canonical namespace/task hygiene:

- `masc_start`
- `masc_status`
- `masc_transition(action="claim")` or `masc_claim_next`
- `masc_plan_set_task` when needed
- `masc_heartbeat`

### 2. Supervised Delivery Swarm

For planner / implementer / supervisor separation:

- Runtime: keeper/worker surfaces directly against board + task hygiene
- Supervisor: `/mcp/operator` with `masc_operator_snapshot`, `masc_operator_digest`, `masc_operator_action`, `masc_operator_confirm`
- Runbooks: [docs/SWARM-DELIVERY-RUNBOOK.md](docs/SWARM-DELIVERY-RUNBOOK.md), [docs/SUPERVISOR-MODE.md](docs/SUPERVISOR-MODE.md)

### 3. Dashboard and Keeper Surfaces

- Monitoring: `http://127.0.0.1:<PORT>/dashboard#monitoring/sessions`
- Ops Queue: `http://127.0.0.1:<PORT>/dashboard#command/intervene`
- Workspace: `http://127.0.0.1:<PORT>/dashboard#workspace/board`
- Lab: `http://127.0.0.1:<PORT>/dashboard#lab/tools`

The dashboard is a read-heavy UI for repo coordination and keeper/runtime visibility. Canonical write paths remain MCP tools.

For external channel adapters, treat the Channel Gate as the boundary owner:

- write/traffic path: `/api/v1/gate/message`
- read/descriptor path: `/api/v1/gate/connectors`
- per-channel metrics path: `/api/v1/gate/status`
- Discord bot setup and live verification: [sidecars/discord-bot/README.md](sidecars/discord-bot/README.md)

The dashboard should learn connector type and status from the gate descriptor
surface instead of hardcoding vendor-specific assumptions.

- `scripts/run-local.sh` does not build the dashboard automatically. Append `--build-dashboard` only when needed.
- `start-masc-mcp.sh` automatically builds the dashboard SPA if `pnpm` or `corepack pnpm` is available.
- To run the dev server separately, use:

```bash
PORT="$(scripts/run-local.sh --print-port --target-dir "$PWD")"
cd dashboard && MASC_DASHBOARD_PROXY_TARGET="http://127.0.0.1:${PORT}" pnpm run dev
```

- For manual rebuilds, run `cd dashboard && pnpm run build`.
- For local admin bearer bootstrap and dashboard keeper lifecycle control, see [docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md).

Fast local auth bootstrap:

```bash
~/me/scripts/masc dashboard-admin
```

Raw JSON path:

```bash
~/me/scripts/masc login --json --agent codex-local-admin
```

Repo-local fallback:

```bash
dune exec --root . ./bin/main_eio.exe -- login --json --agent codex-local-admin
```

Copy-paste example:

```bash
LOGIN_JSON="$(~/me/scripts/masc login --json --agent codex-local-admin)"
TOKEN="$(printf '%s\n' "$LOGIN_JSON" | jq -r '.bearer_token')"
URL="$(printf '%s\n' "$LOGIN_JSON" | jq -r '.dashboard_url')"
printf 'token=%s\nurl=%s\n' "$TOKEN" "$URL"
curl -sS http://127.0.0.1:8935/api/v1/dashboard/shell \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-MASC-Agent: codex-local-admin" \
  | jq '.auth'
```

## Verification

```bash
make test           # Unit tests (no server needed)
make ci             # Full CI suite
```

Smoke checks (with running server):

```bash
curl -sS http://127.0.0.1:8935/health
grpcurl -plaintext 127.0.0.1:8936 grpc.health.v1.Health/Check
make release-evidence
```

To reproduce CI-style test output with heartbeat logs locally:

```bash
CI_TEST_TIMEOUT_SEC=1200 CI_TEST_HEARTBEAT_SEC=30 \
  scripts/ci-run-tests.sh "opam exec -- dune test --root ."
```

## Transport and Auth

- `POST /mcp` expects `Accept: application/json, text/event-stream`.
- Legacy `/sse` and `/messages` endpoints are deprecated.
- Binding to `0.0.0.0` or `::` enables strict auth; local `/mcp` fails closed unless `require_token=true`.
- `/mcp/operator` is bearer-token only with a remote-safe surface. Do not expose full `/mcp` externally.
- Local dashboard/admin auth bootstrap: `~/me/scripts/masc dashboard-admin` (or `~/me/scripts/masc login --json --agent codex-local-admin` for raw JSON)
- Command-plane compatibility is retired from the supported product contract. Historical docs may still mention it, but new callers must not depend on it.
- See [docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md) and [docs/spec/09-server-transport.md](docs/spec/09-server-transport.md).

## Product and Planning Docs

| Document | Description |
|----------|-------------|
| [docs/PRODUCT-OPERATING-PLAN.md](docs/PRODUCT-OPERATING-PLAN.md) | Product promise, GitHub operating model, 6-8 week execution tracks |
| [docs/RELEASE-EVIDENCE.md](docs/RELEASE-EVIDENCE.md) | Reproducible production-evidence contract and current proof bundle shape |
| [ROADMAP.md](ROADMAP.md) | Current package version, latest release truth, active tracks |
| [docs/PRODUCT-REVIEW.md](docs/PRODUCT-REVIEW.md) | Current product posture by promise level |
| [docs/design/keeper-continuity-product-rfc.md](docs/design/keeper-continuity-product-rfc.md) | Bounded keeper continuity contract and promise level |
| [docs/KEEPER-CONTINUITY-PRODUCTION-RUNBOOK.md](docs/KEEPER-CONTINUITY-PRODUCTION-RUNBOOK.md) | Release gate, evidence, monitoring, and rollback for keeper continuity |

## Document Map

| Document | Description |
|----------|-------------|
| [docs/QUICK-START.md](docs/QUICK-START.md) | Install, health check, first workflow |
| [docs/CONFIG-DOCTOR.md](docs/CONFIG-DOCTOR.md) | Active config/init diagnosis and root selection |
| [docs/MCP-TEMPLATE.md](docs/MCP-TEMPLATE.md) | HTTP / stdio MCP config templates |
| [docs/RELEASE-EVIDENCE.md](docs/RELEASE-EVIDENCE.md) | Release-grade smoke checks and proof bundle contract |
| [docs/BENCHMARK-RUNBOOK.md](docs/BENCHMARK-RUNBOOK.md) | Benchmark and comparison harnesses |
| [docs/KEEPER-USER-MANUAL.md](docs/KEEPER-USER-MANUAL.md) | Keeper lifecycle and troubleshooting |
| [docs/SUPERVISOR-MODE.md](docs/SUPERVISOR-MODE.md) | Supervised execution / operator workflow |
| [docs/SWARM-DELIVERY-RUNBOOK.md](docs/SWARM-DELIVERY-RUNBOOK.md) | Single-agent vs swarm delivery |
| [docs/OAS-MASC-BOUNDARY.md](docs/OAS-MASC-BOUNDARY.md) | OAS/MASC ownership boundary |
| [docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md) | Dashboard auth bootstrap |
| [docs/spec/SPEC-INDEX.md](docs/spec/SPEC-INDEX.md) | Spec suite (19 specs) |
| [ROADMAP.md](ROADMAP.md) | Version, release truth, active tracks |
| [docs/PRODUCT-OPERATING-PLAN.md](docs/PRODUCT-OPERATING-PLAN.md) | Product promise, execution tracks |
| [llms.txt](llms.txt) / [llms-full.txt](llms-full.txt) | Compressed front door for language models |

Historical and archived documents remain in the repository, but the front-door SSOT is the README, the product operating plan, the release evidence contract, the roadmap, and the current spec suite.
 
