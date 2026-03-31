# masc-mcp

[![OCaml](https://img.shields.io/badge/OCaml-5.x-orange.svg)](https://ocaml.org/)

`masc-mcp` is an OCaml 5.x + Eio MCP server that keeps multiple coding agents coordinated inside one repository.

It is built for repo-local, single-machine, trusted-network workflows where several AI agents need shared room state, task ownership, broadcasts, worktrees, and supervisor-visible proof instead of ad-hoc terminal coordination.

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

메모:

- target 기준 기본 포트 확인: `scripts/run-local.sh --print-port --target-dir /path/to/project`
- 고정 포트가 필요하면 `scripts/run-local.sh --target-dir /path/to/project --port 94xx`
- shared repo/full-runtime 경로는 `./start-masc-mcp.sh --http`를 계속 사용한다.

If you bind to a non-loopback address such as `0.0.0.0`, treat that as a remote exposure path and configure auth first. See [docs/REMOTE-MCP-OPERATOR.md](docs/REMOTE-MCP-OPERATOR.md) and [docs/spec/09-server-transport.md](docs/spec/09-server-transport.md).

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

dir-local local-dev에서는 `8935` 대신 `scripts/run-local.sh --print-port --target-dir ...` 출력값으로 바꾼다.

메모:

- Normal local use starts with `/mcp`.
- Remote supervision uses bearer-token `/mcp/operator` and the reduced operator profile.
- Full HTTP / stdio templates live in [docs/MCP-TEMPLATE.md](docs/MCP-TEMPLATE.md).

## Safe Starting Paths

### 1. Repo Coordination

The shortest reliable entry path is still:

```text
masc_start(path="/your/project", task_title="My first task")
```

Canonical room/task hygiene:

- `masc_set_room`
- `masc_join`
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

- Monitoring: `http://127.0.0.1:<PORT>/dashboard#monitoring?section=sessions`
- Intervention: `http://127.0.0.1:<PORT>/dashboard#command?section=intervene`
- Governance: `http://127.0.0.1:<PORT>/dashboard#command?section=governance`

The dashboard is a read / operate UI. Canonical write and control paths remain MCP tools.

- 대시보드는 read/operate UI이고, canonical write/control path는 MCP입니다.
- `scripts/run-local.sh`는 dashboard를 자동으로 빌드하지 않습니다. 필요할 때만 `--build-dashboard`를 붙이세요.
- `start-masc-mcp.sh`는 `pnpm` 또는 `corepack pnpm`이 있을 때 dashboard SPA를 자동으로 빌드합니다.
- dev server를 따로 띄울 때는 `PORT="$(scripts/run-local.sh --print-port --target-dir "$PWD")"` 후 `cd dashboard && MASC_DASHBOARD_PROXY_TARGET="http://127.0.0.1:${PORT}" pnpm run dev`를 사용하세요.
- 수동 재빌드가 필요하면 `cd dashboard && pnpm run build`를 실행하세요.

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
- Local `/mcp` is the full MCP surface and should be treated as local-first. On non-loopback bind it fails closed unless room auth is enabled with `require_token=true`.
- `/mcp/operator` is bearer-token only and intentionally exposes a smaller remote-safe surface.
- Remote-safe exposure means `/mcp/operator` only. Do not expose the full `/mcp` surface to external clients unless you intentionally want the full room tool inventory behind bearer auth.

## Product and Planning Docs

- [docs/PRODUCT-OPERATING-PLAN.md](docs/PRODUCT-OPERATING-PLAN.md) — product promise, GitHub operating model, 6-8 week execution tracks
- [ROADMAP.md](ROADMAP.md) — current package version, latest release truth, active tracks
- [docs/PRODUCT-REVIEW.md](docs/PRODUCT-REVIEW.md) — current product posture by promise level
- [docs/design/keeper-continuity-product-rfc.md](docs/design/keeper-continuity-product-rfc.md) — bounded keeper continuity contract and promise level
- [docs/KEEPER-CONTINUITY-PRODUCTION-RUNBOOK.md](docs/KEEPER-CONTINUITY-PRODUCTION-RUNBOOK.md) — release gate, evidence, monitoring, and rollback for keeper continuity

## Document Map

- [docs/QUICK-START.md](docs/QUICK-START.md) — install, health check, first workflow
- [docs/MCP-TEMPLATE.md](docs/MCP-TEMPLATE.md) — HTTP / stdio MCP config templates
- [docs/COMMAND-PLANE-RUNBOOK.md](docs/COMMAND-PLANE-RUNBOOK.md) — benchmark / CPv2 direct path
- [docs/BENCHMARK-RUNBOOK.md](docs/BENCHMARK-RUNBOOK.md) — single-agent vs swarm comparison
- [docs/SUPERVISOR-MODE.md](docs/SUPERVISOR-MODE.md) — supervised team-session / operator workflow
- [docs/REMOTE-MCP-OPERATOR.md](docs/REMOTE-MCP-OPERATOR.md) — remote-safe operator endpoint and confirm flow
- [docs/KEEPER-USER-MANUAL.md](docs/KEEPER-USER-MANUAL.md) — keeper lifecycle and troubleshooting
- [docs/spec/SPEC-INDEX.md](docs/spec/SPEC-INDEX.md) — spec suite front door
- `llms.txt` / `llms-full.txt` — compressed front door for language models

Historical and archived documents remain in the repository, but the front-door SSOT is the README, the product operating plan, the roadmap, and the current spec suite.
