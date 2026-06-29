# Contributing to MASC

MASC is a repo-local MCP server for coordinating Keepers, MCP clients, and workspace state inside one repository. This document is about contributing to this codebase; it is not meant to justify the whole design.

## Quick Start

```bash
# 1. Clone and setup
git clone https://github.com/jeong-sik/masc.git
cd masc

# 2. Pin external OCaml dependencies
chmod +x scripts/opam-pin-external-deps.sh
scripts/opam-pin-external-deps.sh

# 3. Install OCaml dependencies
opam install . --deps-only

# 4. Focused local build
scripts/dune-local.sh build @default

# 5. Run a focused test while developing
scripts/dune-local.sh exec test/test_config_runtime_split.exe

# 6. Start server (HTTP mode)
./start-masc.sh --http
```

## Development Guidelines

### Code Style

- **OCaml 5.x + Eio** — the current project stack; follow existing direct-style Eio patterns
- **No blocking IO** — `Unix.sleepf` / `Lwt.bind` are forbidden; use `Eio.Time.sleep`
- **Type safety** — prefer typed variants/records for runtime contracts, and avoid `Obj.magic`
- **Result types** — Use `Result.t` over exceptions for recoverable errors
- **Resource cleanup** — `Eio.Switch.on_release` over nested `Fun.protect`
- **Pure functions** — extract testable logic from IO code when it keeps the change simpler

### Project Structure

```
bin/
├── main_eio.ml               # Primary HTTP server entry point
├── main_stdio_eio.ml         # stdio compatibility entry point
├── masc_cost.ml              # Cost analysis tool
├── masc_tui.ml               # Terminal UI dashboard
└── ...                       # Additional executables and build files

lib/
├── keeper/                   # keeper runtime and turn loop
├── worker_contract_types/    # worker contract enums and shared runtime types
├── dashboard/                # dashboard providers and read models
├── board/                    # board/social surface helpers
├── grpc/                     # gRPC transport support
├── workspace/                     # workspace/session/task workspace collaboration
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
| **Board** | `lib/board/`, `lib/tool_board.ml` | Posts, votes, comments |
| **Keeper** | `lib/keeper/`, `lib/tool_keeper.ml` | long-running keeper runtime |
| **Worker Contracts** | `lib/worker_contract_types/` | shared worker/runtime contract types |

### Testing

- **Test framework**: Alcotest
- **Test files**: many focused Alcotest suites plus coverage/integration/benchmark harnesses
- **Pure functions**: Tested without mocking
- **IO functions**: tested with integration harnesses when the required service is configured

```bash
# Run a focused test through the repo wrapper
scripts/dune-local.sh exec test/test_config_runtime_split.exe

# Run specific test
scripts/dune-local.sh exec test/<test-name>.exe

# Build only
scripts/dune-local.sh build @default

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
3. **Run relevant local checks** for changed files through `scripts/dune-local.sh`
4. **Let CI own full-suite truth** when the PR opens
5. **Open a draft PR** linked to at least one issue
6. **Include review evidence** when the repo workflow or reviewer asks for it
7. **Wait for review**

### Release Versioning

- The active product line is pre-1.0: use `0.y.0` for a new promise train and `0.y.z` for stabilization inside that train.
- `v2.*` tags are legacy history and are no longer the active release line.
- After a release-line reset or new train bump lands on `main`, publish its tag before opening the next train bump.
  Example: after merging `0.2.0`, tag `v0.2.0` before opening `0.3.0`.
- Use `bash scripts/check-version-truth.sh` and `bash scripts/check-doc-truth.sh` before asking for release review.
- CI also enforces `bash scripts/check-release-train-guard.sh` to block widening an untagged pending train.

## GitHub Planning Rules

`masc` uses GitHub issues, labels, and PRs for product planning.

Every new issue should end with:

- exactly one `type:*`
- exactly one `area:*`
- exactly one `target:*`
- optional `release-blocker`
- optional `product-gap`
- temporary automation label `triage-required` while one of the required planning labels is missing

Current label groups:

- `type:bug`, `type:friction`, `type:feature`, `type:architecture`, `type:docs`
- `area:workspace collaboration`, `area:team-session`, `area:dashboard`, `area:operator`, `area:transport`, `area:config`, `area:ci`, `area:docs`, `area:experimental`
- `target:now`, `target:next`, `target:later`

Triage defaults:

- `target:now` for current product-promise blockers
- `target:next` for advanced workflow improvements
- `target:later` for extraction, speculative platform work, or deep architecture cleanup

See [docs/PRODUCT-OPERATING-PLAN.md](docs/PRODUCT-OPERATING-PLAN.md) for the detailed planning model.

## PR Description Expectations

PRs should include these sections:

- `## Summary`
- `## Product impact`
- `## Evidence`
- `## Review evidence`
- `## Linked issue`

State which promise the PR affects:

- `repo workspace collaboration`
- `ops visibility`
- `none/internal`

Cross-model review evidence should use direct `sb glm-text` when available. If a fallback reviewer is used, record the reason in the PR body or comment.

## Architecture Decisions

### OCaml 5.x + Eio notes

OCaml/Eio is the current implementation stack, not a general recommendation.
The project uses it because it has worked well enough for this experiment and
because most runtime code already follows that shape.

- `Switch.run` scopes fiber lifetime; release resources when the switch exits.
- Compile-time checks catch many record/variant drift errors before runtime.
- The server builds as a native binary.
- Eio uses direct-style async; avoid introducing Lwt-style control flow.

### State Storage

- Runtime state is filesystem-first under `<base-path>/.masc/`.
- State files are JSON/JSONL where practical so operators can inspect them.
- Optional graph/vector integrations are workflow-specific. They are not required for a basic local build, boot, or Keeper turn.

### Runtime Assignment

- Runtime order is controlled by `runtime.toml` at the resolved config root.
- Missing or invalid `runtime.toml` is a config error; the retired `runtime.json` fallback is not used.
- Keeper TOML/profile files do not own concrete model/provider selection.
- Keeper-specific routing lives in `runtime.toml` under `[runtime.assignments]`, keyed by keeper name. Unassigned keepers use `[runtime].default`.
- Runtime catalog changes in `runtime.toml` apply on the next runtime resolve.

### Runtime Lens Boundary (provider/model identity in JSON)

The Runtime Lens redacts provider/model identity at **external** surfaces
(metric labels, dashboard OAS bridge, provider error envelopes,
keeper unified metrics redacted variants). It must **NOT** redact at
**internal observability** surfaces (boot log, audit log,
operator-facing `Log.*.info`).

Before adding a new `*_to_yojson` function or metric emitter that
touches provider/model identity, read
and apply its 3-question decision rule (who reads it / is there a
`redacted_*` companion / sibling field consistency).

Regression coverage lives in
`test/test_runtime_catalog_runtime_yojson.ml` — 8 cases across the two
internal carve-out sites. New internal serializers should add a
companion test there using the helpers (`assoc_string`, substring
scanner).

History: #15040 (introduced lens, over-applied) → #15070 (carve-out for
boot log + audit log) → #15089 (test pins + this section).

## Reporting Issues

When reporting issues, please include:

1. **OCaml version** (`ocaml --version`)
2. **OS and version**
3. **Steps to reproduce**
4. **Expected vs actual behavior**
5. **Error messages/logs** (`start-masc.sh` stdout/stderr or relevant harness output)

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

---

Questions? Open an issue with the reproduction details above.
 
