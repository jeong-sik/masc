# masc-mcp

[![OCaml](https://img.shields.io/badge/OCaml-5.4+-orange.svg)](https://ocaml.org/)
[![OAS](https://img.shields.io/badge/agent__sdk-%E2%89%A50.118.2-blue.svg)](https://github.com/jeong-sik/oas)

Multi-Agent Streaming Coordination server built on OCaml 5.x + Eio. Keeps multiple coding agents coordinated inside one repository through shared namespace, task ownership, broadcasts, worktrees, supervisor-visible proof, and OAS-backed keeper execution.

Built for repo-local, single-machine, trusted-network workflows where several AI agents need shared coordination state instead of ad-hoc terminal coordination.

Current product posture:

- Front-door promise: repo coordination for coding workflows
- Runtime substrate: OAS-backed keeper execution
- Supporting surface: dashboard, activity views, and keeper status
- Legacy or secondary: wider transport matrix, research modules, and retired compatibility surfaces

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
│  Room/Board  Keeper   Team-Session  Governance    │
│  Tasks       Command-Plane         Dashboard      │
│                                                   │
│         ┌── OAS bridges ──┐                       │
└─────────┤                 ├───────────────────────┘
          │                 │
┌─────────▼─────────────────▼──────────────────────┐
│         OAS / agent_sdk  (agent runtime)          │
│  Agent.run  Builder  Hooks  Checkpoint  Memory    │
│  Context_reducer  Tool_selector  Cascade          │
└──────────────────────────────────────────────────┘
```

**MASC** decides when, why, and which agent to run. **OAS** handles single-agent execution, tool dispatch, context management, and LLM provider cascading. MASC depends on OAS; OAS does not know about MASC.

### Transport

All protocols run concurrently from a single Eio fiber pool:

| Protocol | Default | Notes |
|----------|---------|-------|
| HTTP/1.1 + HTTP/2 | `:8935` | Primary MCP endpoint at `/mcp` |
| SSE | `:8935` | Unlimited streams per h2 connection |
| gRPC | `:8936` | Keeper queries and subscriptions |
| WebSocket | `:8937` | Standalone + discovery via `/ws` |
| WebRTC | `:8935/webrtc` | Signaling at `/offer` and `/answer` |

### Tech Stack

- **OCaml 5.4+** with Eio structured concurrency (no Lwt)
- **agent_sdk** >= 0.118.2 (OAS agent runtime)
- **mcp_protocol** >= 1.3.0 (MCP JSON-RPC contract)
- **h2-eio** (HTTP/2), **grpc-direct** (gRPC), **ocaml-webrtc** (WebRTC)
- **caqti** + PostgreSQL (optional), **sqlite3** (fallback), **neo4j_bolt** (optional graph)
- **opentelemetry** (OTLP tracing)

## Quick Start

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

Other start modes:

| Mode | Command | Use case |
|------|---------|----------|
| Loopback | `scripts/start-loopback.sh` | Local dev, fixed port 8935, keepers off |
| Dir-local | `scripts/run-local.sh --target-dir /path` | Per-project isolation, auto port |
| Full runtime | `./start-masc-mcp.sh --http` | All transports, keeper autoboot, dashboard |
| Direct binary | `./_build/default/bin/main_eio.exe --port 8935 --base-path .` | Manual control |

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

Keepers follow an 11-state deterministic state machine:

```
Offline → Running → [Failing|Compacting|HandingOff|Draining]
       → Paused/Stopped/Crashed → Restarting → Dead
```

### Autoboot

Keeper definitions live in `config/keepers/*.toml`. When `MASC_KEEPER_BOOTSTRAP_ENABLED=true`, the server discovers and starts all keepers on boot with staggered warmup delays.

### Turn Budget

Each keeper call to `Agent.run` is limited to `MASC_KEEPER_OAS_MAX_TURNS_PER_CALL` turns (default: 5). When exhausted, the keeper saves a checkpoint and resumes in the next heartbeat cycle. The keeper can call `extend_turns` to request more turns up to an absolute ceiling (200).

Adaptive OAS timeout: `base 180s + 1.5s per 1K context tokens`, capped at [30, 600]s.

### Key Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MASC_KEEPER_BOOTSTRAP_ENABLED` | `false` | Enable keeper autoboot |
| `MASC_KEEPER_HEARTBEAT_INTERVAL_SEC` | `30` | Heartbeat cadence (5-300s) |
| `MASC_KEEPER_OAS_MAX_TURNS_PER_CALL` | `5` | Turns per Agent.run call (1-50) |
| `MASC_KEEPER_OAS_TIMEOUT_SEC` | adaptive | Override OAS timeout (30-600s) |
| `MASC_KEEPER_TURN_TIMEOUT_SEC` | `1200` | Wall-clock turn guard (60-3600s) |
| `MASC_KEEPER_SUPERVISOR_MAX_RESTARTS` | `5` | Restart attempts before Dead |
| `MASC_KEEPER_IDLE_SKIP_THRESHOLD` | `4` | Consecutive idle calls before Skip |

Full list: `lib/config/env_config_keeper.ml`. Per-keeper config: `config/keepers/*.toml`.

## Model Cascade

- `config/cascade.json` follows the OAS cascade contract.
- OAS owns cascade schema, parsing, and label semantics.
- MASC uses that contract to choose repo-level checked-in defaults; each keeper can override via `cascade_name` in its TOML.
- For committed defaults, prefer explicit `provider:model_id` labels instead of convenience labels.
- Any committed `groq:*` tier requires `GROQ_API_KEY` in the runtime environment for that fallback to be usable.
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

- Runtime: command-plane operations + worker/keeper surfaces
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

## Verification

```bash
make test           # Unit tests (no server needed)
make ci             # Full CI suite
```

Smoke checks (with running server):

```bash
curl -sS http://127.0.0.1:8935/health
grpcurl -plaintext 127.0.0.1:8936 grpc.health.v1.Health/Check
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
- Retired compatibility surfaces such as command-plane/operator routes are no longer part of the supported front door.
- See [docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md) and [docs/spec/09-server-transport.md](docs/spec/09-server-transport.md).

## Product and Planning Docs

| Document | Description |
|----------|-------------|
| [docs/PRODUCT-OPERATING-PLAN.md](docs/PRODUCT-OPERATING-PLAN.md) | Product promise, GitHub operating model, 6-8 week execution tracks |
| [ROADMAP.md](ROADMAP.md) | Current package version, latest release truth, active tracks |
| [docs/PRODUCT-REVIEW.md](docs/PRODUCT-REVIEW.md) | Current product posture by promise level |
| [docs/design/keeper-continuity-product-rfc.md](docs/design/keeper-continuity-product-rfc.md) | Bounded keeper continuity contract and promise level |
| [docs/KEEPER-CONTINUITY-PRODUCTION-RUNBOOK.md](docs/KEEPER-CONTINUITY-PRODUCTION-RUNBOOK.md) | Release gate, evidence, monitoring, and rollback for keeper continuity |

## Document Map

| Document | Description |
|----------|-------------|
| [docs/QUICK-START.md](docs/QUICK-START.md) | Install, health check, first workflow |
| [docs/MCP-TEMPLATE.md](docs/MCP-TEMPLATE.md) | HTTP / stdio MCP config templates |
| [docs/BENCHMARK-RUNBOOK.md](docs/BENCHMARK-RUNBOOK.md) | Benchmark and comparison harnesses |
| [docs/KEEPER-USER-MANUAL.md](docs/KEEPER-USER-MANUAL.md) | Keeper lifecycle and troubleshooting |
| [docs/SUPERVISOR-MODE.md](docs/SUPERVISOR-MODE.md) | Supervised execution / operator workflow |
| [docs/SWARM-DELIVERY-RUNBOOK.md](docs/SWARM-DELIVERY-RUNBOOK.md) | Single-agent vs swarm delivery |
| [docs/OAS-MASC-BOUNDARY.md](docs/OAS-MASC-BOUNDARY.md) | OAS/MASC ownership boundary |
| [docs/COMMAND-PLANE-RUNBOOK.md](docs/COMMAND-PLANE-RUNBOOK.md) | Historical compatibility / command-plane details |
| [docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md) | Dashboard auth bootstrap |
| [docs/spec/SPEC-INDEX.md](docs/spec/SPEC-INDEX.md) | Spec suite (19 specs) |
| [ROADMAP.md](ROADMAP.md) | Version, release truth, active tracks |
| [docs/PRODUCT-OPERATING-PLAN.md](docs/PRODUCT-OPERATING-PLAN.md) | Product promise, execution tracks |
| [llms.txt](llms.txt) / [llms-full.txt](llms-full.txt) | Compressed front door for language models |

Historical and archived documents remain in the repository, but the front-door SSOT is the README, the product operating plan, the roadmap, and the current spec suite.
 
