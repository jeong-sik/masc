---
status: design
last_verified: 2026-05-18
issue: https://github.com/jeong-sik/masc-mcp/issues/16083
masc_goal: goal-refactor-lsp-atlas-20260518
masc_task: task-386
code_refs:
  - lib/server/server_ide_lsp_proxy.ml
  - lib/server/lsp_process_manager.ml
  - lib/server/lsp_message_router.ml
  - dashboard/src/components/ide/ide-lsp-client.ts
---

# LSP Symbol Graph Exporter

This is the task-386 design contract for turning the existing dashboard LSP lane into a read-only reverse-engineering atlas.

## Goal

Produce a deterministic symbol graph that can update `docs/reverse-engineering-design.html` with code-level flow evidence before large refactors begin.

The graph must answer:

- Which file defines each important symbol?
- Which ranges participate in a documented flow?
- Which references and call edges cross module boundaries?
- Which tests own each flow contract?
- Which WBS task is allowed to move that code?

## Non-Goals

- No code editing through this lane.
- No LSP rename, formatting, code action, or command execution.
- No keeper claim, task transition, git mutation, or dashboard mutation from the exporter.
- No hidden broad workspace scan without a file manifest and limits.

## Existing Surface

The repo already has a dashboard LSP WebSocket route:

| Surface | Current owner | Relevant behavior |
|---|---|---|
| `/api/v1/ide/lsp` | `server_ide_lsp_proxy.ml` | WebSocket JSON-RPC lane registered with public-read auth boundary. |
| LSP process manager | `lsp_process_manager.ml` | Spawns a language server process under an `Eio.Switch` and tears it down with the connection. |
| Message router | `lsp_message_router.ml` | Maps client IDs to server IDs and resolves pending request promises. |
| Dashboard client | `ide-lsp-client.ts` | Connects to the WebSocket, initializes JSON-RPC, and requests IDE annotations. |

Current main advertises read and write-adjacent LSP capabilities in the generic IDE handshake, so the symbol graph exporter must apply its own stricter method allowlist even if the shared IDE lane remains broader.

## Exporter Shape

Implement the exporter as a separate read-only component, not as another branch inside editor hydration:

| Layer | Responsibility | Write permission |
|---|---|---|
| `Ide_symbol_graph_manifest` | Static manifest of files, WBS lanes, expected tests, and maximum ranges. | none |
| `Ide_symbol_graph_client` | Sends allowlisted LSP requests and normalizes responses. | none |
| `Ide_symbol_graph_builder` | Builds file/symbol/reference/test-owner graph JSON. | none |
| `scripts/ide/export-symbol-graph` or equivalent CLI | Runs the exporter and writes the artifact only when invoked by a developer PR. | repo write by operator command only |
| Optional dashboard `GET` route | Returns graph JSON for a requested file/range without persisting it. | none |

The runtime endpoint, if added, must be `GET` only and must not write cache files. Persistent artifacts are produced by an explicit script during a documentation PR.

## Method Allowlist

Allowed LSP methods:

- `initialize`
- `initialized`
- `shutdown`
- `exit`
- `textDocument/documentSymbol`
- `textDocument/references`
- `textDocument/definition`
- `textDocument/typeDefinition`
- `textDocument/implementation`
- `textDocument/hover`

Rejected methods:

- `textDocument/didChange`
- `textDocument/didSave`
- `workspace/applyEdit`
- `workspace/executeCommand`
- `textDocument/rename`
- `textDocument/formatting`
- `textDocument/rangeFormatting`
- `textDocument/codeAction`
- every `workspace/*` method except passive capability discovery.

If a language server returns a capability that implies mutation, the exporter records it in `omissions[]` and does not call that method.

## Scope And Budgets

Default limits for task-387:

| Limit | Default | Failure mode |
|---|---:|---|
| files per run | 80 | emit `limit_exceeded` omission |
| bytes per file | 512 KiB | skip file, keep manifest row |
| symbols per file | 1,500 | truncate with omission |
| references per symbol | 200 | truncate with omission |
| LSP request timeout | 3 s | mark method timeout and continue |
| run timeout | 180 s | fail the exporter command |

Workspace confinement:

- Manifest paths are repo-relative.
- `file://` URIs must resolve inside the configured workspace root.
- Symlinks must be resolved before request dispatch.
- Paths outside the workspace are omitted, not normalized into absolute paths.

## Artifact Path

Task-387 should generate:

```text
docs/generated/reverse-engineering/symbol-graph.v1.json
```

`docs/reverse-engineering-design.html` should link to the artifact and render only the curated summary. The exporter must not rewrite the HTML automatically; HTML updates stay in normal PR review.

The first snapshot in this PR is a schema-compatible static seed. It records WBS lanes, source owners, guard tests, and curated flow edges, and it explicitly records `live_lsp_not_invoked_in_this_pr` in `omissions[]`. Its `display_range` rows are bound to the JSON `base_commit`, so they are evidence for that commit only and must not be treated as current-main coordinates after main advances. A later implementation PR should replace static ranges with live `documentSymbol` and `references` responses.

## JSON Schema

The first artifact uses `masc.symbol_graph.v1`:

```json
{
  "schema_version": "masc.symbol_graph.v1",
  "repo": "masc-mcp",
  "base_commit": "7dda94cd4f",
  "generated_at": "2026-05-18T00:00:00Z",
  "source": {
    "lsp_route": "/api/v1/ide/lsp",
    "methods": ["textDocument/documentSymbol", "textDocument/references"],
    "manifest": "docs/design/lsp-symbol-graph-exporter.md"
  },
  "limits": {
    "max_files": 80,
    "max_bytes_per_file": 524288,
    "request_timeout_ms": 3000
  },
  "files": [
    {
      "path": "lib/server/server_ide_lsp_proxy.ml",
      "language": "ocaml",
      "symbols": [
        {
          "id": "sym:server_ide_lsp_proxy:add_routes",
          "name": "add_routes",
          "kind": "function",
          "display_range": {"start_line": 580, "end_line": 654},
          "lsp_range": {
            "start": {"line": 579, "character": 0},
            "end": {"line": 654, "character": 0}
          },
          "wbs": {"issue": 16083, "task": "task-385"},
          "tests": ["test/test_server_ide_lsp_proxy.ml"]
        }
      ],
      "test_owners": [
        {
          "test_path": "test/test_server_ide_lsp_proxy.ml",
          "contract": "LSP handshake and workspace scope"
        }
      ]
    }
  ],
  "edges": [
    {
      "kind": "defines",
      "from": "file:lib/server/server_ide_lsp_proxy.ml",
      "to": "sym:server_ide_lsp_proxy:add_routes"
    }
  ],
  "omissions": []
}
```

Range rules:

- `display_range` is one-based and inclusive for documentation links.
- `lsp_range` is zero-based and half-open, matching LSP.
- Every symbol ID is stable across regenerated artifacts unless the symbol path changes.

## Test Ownership Metadata

The exporter should not infer ownership from references alone. It should combine:

1. Explicit manifest rows: WBS issue/task -> files -> expected tests.
2. `dune` test stanza membership where available.
3. `rg` evidence from test files for exported symbol or route names.
4. Manual overrides for cross-cutting flows such as dashboard HTTP/WS/SSE parity.

Each exported WBS slice must include at least one guard test or an omission explaining why no guard exists yet.

## Keeper Work Breakdown

### Small Goal: `task-386`

Design a read-only symbol graph exporter.

Ultra-mini tasks:

1. Name the artifact path and schema version.
2. Define the LSP method allowlist and mutation denylist.
3. Define workspace path confinement rules.
4. Define runtime budgets and omission rows.
5. Define test-owner metadata and WBS links.
6. Link the design from `docs/reverse-engineering-design.html`.

Done evidence:

- This document exists.
- The HTML design artifact links the contract.
- GitHub issue #16083 has a PR evidence comment.

### Small Goal: `task-387`

Generate the first reverse-engineering symbol graph snapshot.

Ultra-mini tasks:

1. Build a manifest for the six refactor lanes in #16077.
2. Export at least these current owners: MCP request context, keeper turn, task/goal lifecycle, dashboard read model, JSONL writer, LSP route.
3. Emit `docs/generated/reverse-engineering/symbol-graph.v1.json`.
4. Add a small HTML summary that links the JSON artifact.
5. Record omissions for symbols or references that LSP cannot resolve.

Done evidence:

- Generated JSON validates against the schema fields above.
- HTML contains the artifact link and generation commit.
- The run command and omission count are posted to #16083.

## Acceptance Checks

- `rg "lsp-symbol-graph-exporter" docs/reverse-engineering-design.html docs/design/lsp-symbol-graph-exporter.md`
- `rg "masc.symbol_graph.v1|task-386|task-387" docs/design/lsp-symbol-graph-exporter.md`
- `xmllint --html --noout docs/reverse-engineering-design.html`
