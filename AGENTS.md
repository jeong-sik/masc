# MASC-MCP Agent Instructions

Multi-Agent Streaming Coordination server.

**Common mistakes: `docs/COMMON-PITFALLS.md`** — read before refactoring or deleting modules.

Current SSOTs:

- Public overview: `README.md`
- Spec suite front door: `docs/spec/SPEC-INDEX.md`
- Current system overview: `docs/spec/01-system-overview.md`
- Public MCP surface and grouping: `docs/MCP-SURFACE-AUDIT.md`
- Canonical public overview: `README.md`

Notes:

- Tool counts and module snapshots in this file are approximate and may drift.
- Prefer script-based local start flows.

## Commands

```bash
# Build
dune build --root .

# Test
dune runtest --root .
make test

# Run (dev)
./start-masc-mcp.sh --http --port 8935

# Type check only
dune build --root . @check
```

## Project Structure

```
bin/
  main_eio.ml           # Primary HTTP server entry point
  main_stdio_eio.ml     # stdio compatibility entry point
lib/
  command_plane/        # command-plane subsystems
  keeper/               # keeper runtime and turn loop
  team_session/         # team-session engine and artifacts
  dashboard/            # dashboard providers and read models
  board/                # board and social surface helpers
  room/                 # room/session/task coordination
dashboard/              # Preact/TypeScript dashboard source
docs/spec/              # living specification suite
scripts/                # harnesses, CI helpers, local review helpers
test/                   # Alcotest suites and fixtures
```

## Tech Stack

| Layer | Technology | Version |
|-------|-----------|---------|
| Language | OCaml | 5.x |
| Async | Eio | 1.0+ |
| HTTP | httpun_eio | HTTP/1.1 |
| JSON | yojson + ppx_deriving_yojson | 2.0+ / 3.6+ |
| GraphQL Client | cohttp-eio | 6.0+ |
| Neo4j | neo4j_bolt_eio | 0.4+ |
| PostgreSQL | caqti-eio + caqti-driver-postgresql | 2.1+ |
| Build | dune | 3.13 |

## Code Conventions

### OCaml Patterns

- **Parse, Don't Validate**: Use newtype modules (Post_id, Agent_id, Task_id) — no raw strings for IDs
- **Eio.Mutex for shared state**: `use_rw ~protect:true` for writes, `use_ro` for reads
- **Result types** for fallible operations — avoid exceptions for expected failures
- **Fun.protect ~finally** for resource cleanup (not bare try/with)
- **No Obj.magic** — find the correct type instead

```ocaml
(* Correct: newtype module for type safety *)
module Post_id : sig
  type t
  val of_string : string -> (t, string) result
  val to_string : t -> string
end

(* Correct: Eio mutex pattern *)
let with_lodge_lock f =
  match !lodge_lock with
  | Some mutex -> Eio.Mutex.use_rw ~protect:true mutex f
  | None -> f ()

(* Correct: local heartbeat model-pool config *)
let heartbeat_action_models = [
  "llama:qwen3.5-35b-a3b-ud-q8-xl";
  "glm:glm-4.7";
]
```

### Naming

- Module files: `snake_case.ml`
- Types: `snake_case`
- Variants: `PascalCase`
- Functions: `snake_case`
- Config: `SCREAMING_SNAKE_CASE` for env vars

### Error Handling

- Return `(bool * string)` for tool handler results (true = success)
- Return `(ok_type, Types.masc_error) result` for Room operations
- Log with `Eio.traceln` (structured), `Printf.printf` (progress), `Printf.eprintf` (errors)

## Testing

```bash
# Full test suite
dune runtest --root .

# Single test
dune exec --root . test/test_board.exe

# Type check without linking
dune build --root . @check
```

- Tests use `Alcotest` framework
- Board tests verify crypto ID generation, TTL sweeping, path traversal safety
- Metrics tests verify JSONL append and aggregation

## Git Workflow

- Branch: `feature/description` or `fix/description`
- Commit prefix: `feat`, `fix`, `refactor`, `docs`, `chore`, `test`
- PR: always Draft first, squash merge
- No force push to main

## Protocols

| Protocol | Status | Spec |
|----------|--------|------|
| MCP (Layer 2) | Production | JSON-RPC over SSE + POST |
| A2A (Layer 3) | Partial | Agent Card + delegation + subscription |
| AG-UI (Layer 1) | Planned | SSE event mapping |

## Infrastructure

| Service | Endpoint |
|---------|----------|
| MASC Dev | `localhost:8935` |
| MASC Prod | `localhost:8945` (Cloudflare tunnel: `masc.crying.pictures`) |
| GraphQL | `second-brain-graphql-production.up.railway.app` |
| Neo4j | `turntable.proxy.rlwy.net:11490` |

## Boundaries

### Always Do

- Run `dune build --root .` after any .ml file change to verify compilation
- Use newtype modules for IDs (Post_id, Agent_id, Task_id)
- Protect shared mutable state with Eio.Mutex
- Use `Fun.protect ~finally` for resource cleanup
- Add `[@@deriving yojson]` for types that cross JSON boundaries
- Check GraphQL cost limits (GRAPHQL_MAX_COST = 2000)

### Ask First

- Changes to `room.ml` state machine (affects all coordination)
- Changes to `lodge_heartbeat.ml` tick logic (affects autonomous agents)
- Adding new MCP tool registrations in `tools.ml`
- Modifying `config/cascade.json` model ordering
- Changes to `board.ml` post ID generation (cryptographic)

### Never Do

- Use `Obj.magic` to bypass type system
- Commit API keys or tokens (use env vars via `env_config.ml`)
- Force push to main
- Remove the Eio.Mutex protection on `active_agents`
- Call Neo4j directly — use GraphQL layer (`sb graphql`)
- Add blocking I/O in Eio fibers (use Eio equivalents)
