# MASC-MCP Agent Instructions

Shared agent entrypoint for this repo.
Keep this file short. If guidance conflicts, prefer the linked runbooks and specs.

## Read First

- `docs/COMMON-PITFALLS.md` — refactor/deletion traps and dashboard gotchas
- `README.md` — public overview and dashboard entrypoints
- `docs/QUICK-START.md` — install, run, health check
- `docs/MCP-SURFACE-AUDIT.md` — current public MCP surface
- `docs/spec/SPEC-INDEX.md` — spec suite front door
- `docs/COMMAND-PLANE-RUNBOOK.md` — CPv2 direct control path
- `docs/BENCHMARK-RUNBOOK.md` — benchmark and swarm recipes
- `docs/SUPERVISOR-MODE.md` — supervisor/operator path

## Common Commands

```bash
dune build --root .
dune runtest --root .
make test

./start-masc-mcp.sh --http
PORT="$(./start-masc-mcp.sh --print-port)"
curl "http://127.0.0.1:${PORT}/health"

cd dashboard && MASC_DASHBOARD_PROXY_TARGET="http://127.0.0.1:${PORT}" npm run dev
cd dashboard && npm run build
```

- Repo root checkout default port: `8935`
- Git worktrees use a derived port; query it with `./start-masc-mcp.sh --print-port`
- Prefer script-based local start flows; do not treat `launchd` as the default path

## Working Rules

- Run `dune build --root .` after `.ml` changes
- Run `cd dashboard && npm run build` after dashboard changes
- Use newtype modules for IDs; do not pass raw strings across typed boundaries
- Protect shared mutable state with `Eio.Mutex`
- Use established Eio cleanup/resource patterns already present in the touched module
- Use GraphQL access paths; do not add direct Neo4j calls
- Keep provider/model selection in cascade config or env, not hardcoded in feature code
- Treat `README.md`, `docs/QUICK-START.md`, and the runbooks as front-door usage SSOTs, not this file

## Ask First

- `room.ml` state machine changes
- `keeper_keepalive.ml` tick logic changes
- new public MCP tool registrations
- `config/cascade.json` ordering changes
- board post ID generation changes

## Never Do

- use `Obj.magic`
- add blocking I/O inside Eio fibers
- commit secrets or tokens
- force-push `main`
- remove mutex protection around shared runtime state
