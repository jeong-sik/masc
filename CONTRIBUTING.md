# Contributing to MASC MCP

MASC (Multi-Agent Streaming Coordination) is an OCaml 5.x MCP server for coordinating multiple coding agents inside one repository.

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
./start-masc-mcp.sh --http
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
bin/
├── main_eio.ml               # Primary HTTP server entry point
├── main_stdio_eio.ml         # stdio compatibility entry point
├── masc_cost.ml              # Cost analysis tool
├── masc_tui.ml               # Terminal UI dashboard
└── ...                       # Additional executables and build files

lib/
├── command_plane/            # CPv2 orchestration subsystems
├── keeper/                   # keeper runtime and turn loop
├── worker_contract_types/    # worker contract enums and shared runtime types
├── dashboard/                # dashboard providers and read models
├── board/                    # board/social surface helpers
├── grpc/                     # gRPC transport support
├── room/                     # room/session/task coordination
└── tools.ml                  # tool schema registry entrypoint

dashboard/                    # TypeScript + Preact SPA source
docs/spec/                    # living specification suite
scripts/                      # harnesses, CI helpers, review tooling
test/                         # Alcotest suites + fixtures
```

### Key Subsystems

| Subsystem | Entry Point | Description |
|-----------|-------------|-------------|
| **MCP Server** | `bin/main_eio.ml`, `lib/mcp_server_eio_*` | JSON-RPC over Streamable HTTP |
| **Room** | `lib/room/`, `lib/tool_room.ml` | Agent collaboration rooms |
| **Board** | `lib/board/`, `lib/tool_board.ml` | Posts, votes, comments |
| **Command Plane** | `lib/command_plane/`, `lib/tool_command_plane.ml` | units, operations, detachments, policies |
| **Keeper** | `lib/keeper/`, `lib/tool_keeper.ml` | long-running keeper runtime |
| **Worker Contracts** | `lib/worker_contract_types/` | shared worker/runtime contract types |
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

# Build + run a Valgrind leak check on the HTTP server startup/MCP smoke path
make check-memory-leak
```

- `make check-memory-leak` builds `bin/main_eio.exe`, starts it under Valgrind memcheck, waits for `/health`, runs `initialize` + `tools/list`, and fails on definite / indirect / possible leaks.
- Prerequisites: `dune`, `curl`, `python3`, and `valgrind`.
- Useful overrides:
  - `MASC_MAIN_EIO_EXE=/abs/path/to/main_eio.exe make check-memory-leak`
  - `VALGRIND_BIN=/abs/path/to/valgrind make check-memory-leak`
  - `bash scripts/check-memory-leak.sh --skip-build --keep-artifacts`

### External Dependencies

| Service | Purpose | Required |
|---------|---------|----------|
| GraphQL API / Neo4j | agent graph and identity-backed features | Optional by workflow |
| Supabase pgvector / PostgreSQL | persistence and vector-backed features | Optional by workflow |
| local llama / cloud model providers | inference-backed tools, swarm/runtime paths | Optional by workflow |

### Commit Messages

Use conventional commits:

```
feat(governance): add review queue guard
fix(heartbeat): reduce GraphQL query cost under limit
refactor(keeper): rename persona to agent terminology
test(governance): add review queue persistence tests
docs: update CONTRIBUTING for current architecture
chore: bump version to 0.9.0
```

## Pull Request Process

1. **Create branch**: `feat/description` or `fix/description`
2. **Write tests** for new functionality
3. **Run tests**: `make test` must pass
4. **Build**: `dune build` must succeed cleanly
5. **Open a draft PR** linked to at least one issue
6. **Include review evidence** from a non-self model
7. **Wait for review**

### Release Versioning

- The active product line is pre-1.0: use `0.y.0` for a new promise train and `0.y.z` for stabilization inside that train.
- `v2.*` tags are legacy history and are no longer the active release line.
- After a release-line reset or new train bump lands on `main`, publish its tag before opening the next train bump.
  Example: after merging `0.2.0`, tag `v0.2.0` before opening `0.3.0`.
- Use `bash scripts/check-version-truth.sh` and `bash scripts/check-doc-truth.sh` before asking for release review.
- CI also enforces `bash scripts/check-release-train-guard.sh` to block widening an untagged pending train.

## GitHub Planning Rules

`masc-mcp` uses GitHub as an operating system for product planning.

Every new issue should end with:

- exactly one `type:*`
- exactly one `area:*`
- exactly one `target:*`
- optional `release-blocker`
- optional `product-gap`
- temporary automation label `triage-required` while one of the required planning labels is missing

Current label groups:

- `type:bug`, `type:friction`, `type:feature`, `type:architecture`, `type:docs`
- `area:coordination`, `area:team-session`, `area:dashboard`, `area:operator`, `area:transport`, `area:config`, `area:ci`, `area:docs`, `area:experimental`
- `target:now`, `target:next`, `target:later`

Triage defaults:

- `target:now` for current product-promise blockers
- `target:next` for advanced workflow improvements
- `target:later` for extraction, speculative platform work, or deep architecture cleanup

See [docs/PRODUCT-OPERATING-PLAN.md](docs/PRODUCT-OPERATING-PLAN.md) for the full operating model.

## PR Description Expectations

PRs should include these sections:

- `## Summary`
- `## Product impact`
- `## Evidence`
- `## Review evidence`
- `## Linked issue`

State which promise the PR affects:

- `repo coordination`
- `delivery swarm`
- `ops visibility`
- `none/internal`

Cross-model review evidence should use direct `sb glm-text` when available. If a fallback reviewer is used, record the reason in the PR body or comment.

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
5. **Error messages/logs** (`start-masc-mcp.sh` stdout/stderr or relevant harness output)

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

---

Questions? Open an issue or reach out to maintainers.
 
