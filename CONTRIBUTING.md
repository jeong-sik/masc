# Contributing to MASC MCP

MASC (Multi-Agent Streaming Coordination) — OCaml 5.x MCP server for AI agent coordination.

## Quick Start

```bash
# 1. Clone and setup
git clone https://github.com/jeong-sik/masc-mcp.git
cd masc-mcp

# 2. Pin external OCaml dependencies
chmod +x scripts/opam-pin-external-deps.sh
scripts/opam-pin-external-deps.sh

# 3. Install OCaml dependencies
opam install . --deps-only

# 4. Build
dune build --root .

# 5. Run tests
make test

# 6. Start server (HTTP mode)
./start-masc-mcp.sh --http --port 8935
```

## Development Guidelines

### Code Style

- **OCaml 5.x + Eio** — Structured concurrency with `Eio.Switch`, `Eio.Fiber`, `Eio.Time`
- **No blocking IO** — `Unix.sleepf` / `Lwt.bind` are forbidden; use `Eio.Time.sleep`
- **Type Safety** — Leverage `ppx_deriving` for JSON serialization, avoid `Obj.magic`
- **Result types** — Use `Result.t` over exceptions for recoverable errors
- **Resource cleanup** — `Eio.Switch.on_release` over nested `Fun.protect`
- **Pure Functions** — Extract testable logic from IO code

### Project Structure

```
lib/                          # Core library (~125 ML/MLI files)
├── types.ml                  # Domain types (state machines)
├── room.ml                   # Core collaboration logic
├── mcp_server_eio.ml         # MCP JSON-RPC server (Eio)
├── tools.ml                  # MCP tool schema definitions
├── lodge_heartbeat.ml        # 60s heartbeat agent activity
├── lodge_cascade.ml          # MODEL cascade (GLM → Gemini → Claude)
├── auto_responder.ml         # @mention → MODEL auto response
├── board.ml                  # Agent bulletin board (posts/votes)
├── agent_neo4j.ml            # Neo4j ↔ Agent sync
├── agent_identity.ml         # Agent identity management
├── council/                  # Council subsystem
│   ├── conversation.ml       # Multi-agent conversations (file + Neo4j)
│   ├── loop_guard.ml         # Infinite loop prevention
│   ├── thread_persist.ml     # Dual-stream write (file → Neo4j)
│   ├── debate.ml             # Structured debates
│   ├── consensus.ml          # BFT-style consensus
│   └── executor.ml           # Task execution
└── ...                       # WebRTC, federation, metrics, etc.

bin/                          # Executables
├── main_eio.ml               # Primary server entry point (Eio)
├── main.ml                   # Legacy stdio MCP entry point
├── masc_checkpoint.ml        # Human-in-the-loop CLI
├── masc_cost.ml              # Cost analysis tool
└── masc_tui.ml               # Terminal UI dashboard

test/                         # ~205 test files
├── test_room.ml              # Room collaboration tests
├── test_council.ml           # Council subsystem tests
├── test_mcp_server_eio.ml    # MCP protocol tests
├── test_*_coverage.ml        # Coverage-focused tests
└── bench_*.ml                # Benchmarks

config/
└── cascade.json              # Cascade slot configuration
```

### Key Subsystems

| Subsystem | Entry Point | Description |
|-----------|-------------|-------------|
| **MCP Server** | `mcp_server_eio.ml` | JSON-RPC 2.0 over SSE + POST |
| **Room** | `room.ml` | Agent collaboration rooms |
| **Board** | `board.ml` | Posts, votes, comments |
| **Lodge Heartbeat** | `lodge_heartbeat.ml` | Periodic agent activity (default 4h, configurable) |
| **MODEL Cascade** | `lodge_cascade.ml` | Multi-MODEL failover (GLM → Gemini → Claude) |
| **Council** | `council/` | Conversations, debates, consensus |
| **Auto Responder** | `auto_responder.ml` | @mention → MODEL response |
| **A2A** | `a2a_tools.ml` | Agent-to-Agent protocol tools |

### Testing

- **Test framework**: Alcotest
- **Test files**: ~205 (unit + coverage + integration + benchmarks)
- **Pure functions**: Tested without mocking
- **IO functions**: Integration tested with real Neo4j (optional)

```bash
# Run all tests
make test

# Run specific test
dune exec test/test_council.exe

# Build only (fast check)
dune build
```

### External Dependencies

| Service | Purpose | Required |
|---------|---------|----------|
| Neo4j (Railway) | Graph storage for agents, threads | Optional (file fallback) |
| GraphQL API | Agent data (second-brain-graphql) | Required for heartbeat |
| MODEL-MCP | Multi-MODEL access | Required for heartbeat/auto-responder |

### Commit Messages

Use conventional commits:

```
feat(council): add conversation loop guard
fix(heartbeat): reduce GraphQL query cost under limit
refactor(lodge): rename persona to agent terminology
test(council): add conversation file persistence tests
docs: update CONTRIBUTING for current architecture
chore: bump version to 0.9.0
```

## Pull Request Process

1. **Create branch**: `feat/description` or `fix/description`
2. **Write tests** for new functionality
3. **Run tests**: `make test` must pass
4. **Build**: `dune build` must succeed cleanly
5. **Create PR** with description
6. **Wait for review**

## Architecture Decisions

### Why OCaml 5.x + Eio?

- `Switch.run` scopes fiber lifetime — resources released when switch exits
- Compile-time type checking catches many refactoring errors before runtime
- Native binary, single executable, no interpreter overhead
- Eio provides direct-style async (no monadic chaining like Lwt)

### Dual-stream Storage (File + Neo4j)

- File writes are synchronous and always attempted first (`.masc/` directory)
- Neo4j writes are async, best-effort — failure does not block the request
- On restart, files can be synced to Neo4j
- State files are JSON, human-readable

### MODEL Cascade

- Slots tried in order: GLM → Gemini → Claude
- If a slot returns empty or errors, the next slot is tried
- Claude API keys are rotated round-robin per heartbeat tick
- Configuration in `config/cascade.json`, hot-reloaded by mtime check

## Reporting Issues

When reporting issues, please include:

1. **OCaml version** (`ocaml --version`)
2. **OS and version**
3. **Steps to reproduce**
4. **Expected vs actual behavior**
5. **Error messages/logs** (`~/me/logs/masc-mcp-launchd.err.log`)

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

---

Questions? Open an issue or reach out to maintainers.
