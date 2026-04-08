# masc-mcp

[![OCaml](https://img.shields.io/badge/OCaml-5.x-orange.svg)](https://ocaml.org/)

`masc-mcp` is an OCaml 5.x + Eio MCP server that keeps multiple coding agents coordinated inside one repository.

It is built for repo-local, single-machine, trusted-network workflows where several AI agents need shared coordination state in the default project namespace, task ownership, broadcasts, worktrees, and supervisor-visible proof instead of ad-hoc terminal coordination.

Current product posture:

- Front-door promise: repo coordination for coding workflows
- Advanced path: supervised delivery swarm through Team Session + Supervisor
- Supporting surface: dashboard and remote-safe operator tools
- Experimental or secondary: wider transport matrix, research modules, and non-canonical legacy surfaces

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

## Quick Start

```bash
git clone https://github.com/jeong-sik/masc-mcp.git
cd masc-mcp

chmod +x scripts/opam-pin-external-deps.sh
scripts/opam-pin-external-deps.sh

opam install . --deps-only
dune build --root .

scripts/run-local.sh --target-dir "$PWD"
PORT="$(scripts/run-local.sh --print-port --target-dir "$PWD")"
curl "http://127.0.0.1:${PORT}/health"
```

Defaults:

- local-dev HTTP / MCP port: `9100-9999` 범위에서 target path 기준 자동 파생
- 기본 bind host: `127.0.0.1`
- local-dev data root: `<target>/.masc/`
- local-dev config root: `<target>/.masc/config`
- local-dev personas root: `<target>/.masc/config/personas`
- local-dev transports: HTTP on, gRPC/WS/WebRTC off

Notes:

- Check the default port for a target: `scripts/run-local.sh --print-port --target-dir /path/to/project`
- To use a fixed port: `scripts/run-local.sh --target-dir /path/to/project --port 94xx`
- For shared repo/full-runtime paths, continue using `./start-masc-mcp.sh --http`.

If you bind to a non-loopback address such as `0.0.0.0`, treat that as a remote exposure path and configure auth first. See [docs/REMOTE-MCP-OPERATOR.md](docs/REMOTE-MCP-OPERATOR.md) and [docs/spec/09-server-transport.md](docs/spec/09-server-transport.md).

## Local Development Guide

If you run a single `masc-mcp` instance on one machine, the simplest local-dev path is:

```bash
cd /path/to/masc-mcp
scripts/start-loopback.sh
```

This path is the easiest default when you want local MCP development plus transport testing on the same box.

- shortcut script: `scripts/start-loopback.sh`
- keep the server loopback-only with `--host 127.0.0.1`
- keep keeper autoboot off by default on this shortcut path; override with `MASC_KEEPER_BOOTSTRAP_ENABLED=true scripts/start-loopback.sh` when you intentionally want bootstrap scan on local 8935
- keep the fixed default ports when you are not juggling multiple instances:
  - HTTP / MCP: `127.0.0.1:8935`
  - gRPC: `127.0.0.1:8936`
  - WebSocket discovery: `http://127.0.0.1:8935/ws`
  - standalone WebSocket: `ws://127.0.0.1:8937/`
  - WebRTC signaling: `http://127.0.0.1:8935/webrtc/offer` and `/webrtc/answer`
- prefer `./start-masc-mcp.sh --http` over `scripts/run-local.sh` when you want the shared/full-runtime transport surface; `run-local.sh` is for dir-local isolation and disables gRPC / WS / WebRTC by default

Minimal smoke checks:

```bash
curl -sS http://127.0.0.1:8935/health
curl -sS http://127.0.0.1:8935/ws
grpcurl -plaintext 127.0.0.1:8936 grpc.health.v1.Health/Check
MASC_HTTP_PORT=8935 MASC_GRPC_PORT=8936 MASC_WS_PORT=8937 MASC_TRANSPORT_AUTOSTART=0 bash scripts/harness/transport/verify_ws.sh
MASC_HTTP_PORT=8935 MASC_GRPC_PORT=8936 MASC_WS_PORT=8937 MASC_TRANSPORT_AUTOSTART=0 bash scripts/harness/transport/verify_grpc_subscribe.sh
MASC_HTTP_PORT=8935 MASC_GRPC_PORT=8936 MASC_WS_PORT=8937 MASC_TRANSPORT_AUTOSTART=0 bash scripts/harness/transport/verify_webrtc_signaling.sh
```

Things to watch:

- do not bind `0.0.0.0` or `::` for routine local development; that moves you onto the remote-exposure path and auth requirements become stricter
- do not point `MASC_HTTP_BASE_URL` at a public host when you only want local development
- if you only need target-scoped `.masc/` isolation and do not need gRPC / WS / WebRTC, use `scripts/run-local.sh` instead
- `scripts/start-loopback.sh` is a thin wrapper over `MASC_KEEPER_BOOTSTRAP_ENABLED=false ./start-masc-mcp.sh --http --host 127.0.0.1 --port 8935`; pass extra args after it only when you intentionally want to override the defaults

## MCP Client Setup

Local full-surface MCP example:

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

For a dir-local `local-dev` environment, replace `8935` with the output of `scripts/run-local.sh --print-port --target-dir ...`.

Notes:

- Normal local use starts with `/mcp`.
- Remote supervision uses bearer-token `/mcp/operator` and the reduced operator profile.
- Full HTTP / stdio templates live in [docs/MCP-TEMPLATE.md](docs/MCP-TEMPLATE.md).
- `masc_web_search` is a read-only current-information lookup tool. By default it prefers configured official providers (`brave`, `tavily`, `exa`, `bing_api`) and falls back to `duckduckgo` / `bing_rss` scraping when credentials are absent or providers fail.

## Model Cascade Ownership

- `config/cascade.json` follows the OAS cascade contract.
- OAS owns cascade schema, parsing, and label semantics.
- MASC uses that contract to choose repo-level checked-in defaults; it does not redefine cascade semantics.
- For committed defaults, prefer explicit `provider:model_id` labels. Runtime convenience labels such as `provider:auto` may still exist, but they are not the preferred repo-default policy.
- See [docs/OAS-MASC-BOUNDARY.md](docs/OAS-MASC-BOUNDARY.md), [docs/spec/13-oas-integration.md](docs/spec/13-oas-integration.md), and [docs/spec/14-configuration.md](docs/spec/14-configuration.md).

## Safe Starting Paths

### 1. Repo Coordination

The shortest reliable entry path is still:

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

Use this when a feature slice needs planner / implementer / supervisor separation:

- Team session path: `masc_team_session_*`
- Supervisor path: `/mcp/operator` with `masc_operator_snapshot`, `masc_operator_digest`, `masc_operator_action`, `masc_operator_confirm`

The canonical runbooks are [docs/SWARM-DELIVERY-RUNBOOK.md](docs/SWARM-DELIVERY-RUNBOOK.md) and [docs/SUPERVISOR-MODE.md](docs/SUPERVISOR-MODE.md).

### 3. Dashboard and Operator Surfaces

Common entrypoints:

- Monitoring: `http://127.0.0.1:<PORT>/dashboard#monitoring/sessions`
- Intervention: `http://127.0.0.1:<PORT>/dashboard#command/intervene`
- Governance: `http://127.0.0.1:<PORT>/dashboard#command/governance`

The dashboard is a read / operate UI. Canonical write and control paths remain MCP tools.

- `scripts/run-local.sh` does not build the dashboard automatically. Append `--build-dashboard` only when needed.
- `start-masc-mcp.sh` automatically builds the dashboard SPA if `pnpm` or `corepack pnpm` is available.
- To run the dev server separately: 
  `PORT="$(scripts/run-local.sh --print-port --target-dir "$PWD")"`
  `cd dashboard && MASC_DASHBOARD_PROXY_TARGET="http://127.0.0.1:${PORT}" pnpm run dev`
- For manual rebuilds, run `cd dashboard && pnpm run build`.
- For local admin bearer bootstrap and dashboard keeper lifecycle control, see [docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md).

## Verification

```bash
make test
make ci
```

To reproduce CI-style test output with heartbeat logs locally:

```bash
CI_TEST_TIMEOUT_SEC=1200 CI_TEST_HEARTBEAT_SEC=30 \
  scripts/ci-run-tests.sh "opam exec -- dune test --root ."
```

## Transport and Auth Notes

- `POST /mcp` expects `Accept: application/json, text/event-stream`.
- Legacy `/sse` and `/messages` endpoints are deprecated.
- Binding to `0.0.0.0` or `::` enables strict auth on MCP routes.
- Local `/mcp` is the full MCP surface and should be treated as local-first. On non-loopback bind it fails closed unless MASC auth is enabled with `require_token=true`.
- `/mcp/operator` is bearer-token only and intentionally exposes a smaller remote-safe surface.
- Remote-safe exposure means `/mcp/operator` only. Do not expose the full `/mcp` surface to external clients unless you intentionally want the full coordination tool inventory behind bearer auth.

## Product and Planning Docs

- [docs/PRODUCT-OPERATING-PLAN.md](docs/PRODUCT-OPERATING-PLAN.md) — product promise, GitHub operating model, 6-8 week execution tracks
- [ROADMAP.md](ROADMAP.md) — current package version, latest release truth, active tracks
- [docs/PRODUCT-REVIEW.md](docs/PRODUCT-REVIEW.md) — current product posture by promise level
- [docs/design/keeper-continuity-product-rfc.md](docs/design/keeper-continuity-product-rfc.md) — bounded keeper continuity contract and promise level
- [docs/KEEPER-CONTINUITY-PRODUCTION-RUNBOOK.md](docs/KEEPER-CONTINUITY-PRODUCTION-RUNBOOK.md) — release gate, evidence, monitoring, and rollback for keeper continuity

## Document Map

- [docs/QUICK-START.md](docs/QUICK-START.md) — install, health check, first workflow
- [docs/MCP-TEMPLATE.md](docs/MCP-TEMPLATE.md) — HTTP / stdio MCP config templates
- [docs/COMMAND-PLANE-RUNBOOK.md](docs/COMMAND-PLANE-RUNBOOK.md) — managed-operation compatibility lane and command-plane details
- [docs/BENCHMARK-RUNBOOK.md](docs/BENCHMARK-RUNBOOK.md) — single-agent vs swarm comparison
- [docs/SUPERVISOR-MODE.md](docs/SUPERVISOR-MODE.md) — supervised team-session / operator workflow
- [docs/REMOTE-MCP-OPERATOR.md](docs/REMOTE-MCP-OPERATOR.md) — remote-safe operator endpoint and confirm flow
- [docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md](docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md) — local admin bearer bootstrap, base-path checks, and dashboard keeper lifecycle control
- [docs/KEEPER-USER-MANUAL.md](docs/KEEPER-USER-MANUAL.md) — keeper lifecycle and troubleshooting
- [docs/spec/SPEC-INDEX.md](docs/spec/SPEC-INDEX.md) — spec suite front door
- `llms.txt` / `llms-full.txt` — compressed front door for language models

Historical and archived documents remain in the repository, but the front-door SSOT is the README, the product operating plan, the roadmap, and the current spec suite.
