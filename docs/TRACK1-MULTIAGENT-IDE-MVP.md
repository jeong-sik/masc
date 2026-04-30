# Track 1 Multi-Agent IDE MVP

Status: implementation slice
Source: `/Users/dancer/Downloads/multiagent-ide-deep-analysis.md` (local report, 2026-04-29)
Verified: 2026-04-30

## Scope

Track 1 maps to the report's Phase 1/MVP stack:

- Yjs document updates over `yjs:projection:*`
- Yjs Awareness over `yjs:awareness:*`
- CodeMirror 6 read-only code viewer backed by server-authored projection docs
- cytoscape.js Git graph projection grouped by agent/keeper
- TODO Claim + Turn Queue as observation-driven coordination
- OpenTelemetry-ready attributes for collaboration frame flow

## Boundary

MASC owns the product semantics:

- keeper/task/board/turn-queue state
- branch and worktree visualization
- operator dashboard projections
- TODO claim policy and CAS authority

OAS stays a generic agent runtime. It can expose runtime events, raw traces,
proof records, and OTel spans, but it must not learn MASC-specific CRDT doc
ids, keeper slots, board semantics, or branch-visualization policy.

## Layer Model

Track 1 follows `docs/rfc/RFC-0017-ocaml-crdt-boundary.md`.

| Layer | Writer | Dashboard contract |
|-------|--------|--------------------|
| Authority | OCaml runtime | Existing RPC/REST/CAS transitions only |
| Projection | Server-authored Yjs doc updates | `yjs:projection:*` frames, read-only client handling |
| Ephemeral | Browser clients | `yjs:awareness:*` frames for cursor/selection/presence |

Client writes to projection docs are rejected explicitly with `yjs:reject`.
This keeps keeper FSM/TLA invariants in the authoritative OCaml layer.

## Current Slice

The dashboard now has a pure Track 1 frame contract in
`dashboard/src/collaboration-track1.ts`.

It provides:

- recognized dashboard projection doc IDs
- parser for `yjs:projection:*`, `yjs:awareness:*`, and `yjs:reject`
- TODO claim convergence verifier for UI state
- OpenTelemetry-ready `masc.collab.*` attributes that do not include binary
  update payload bytes

The dashboard also has a first projection builder in
`dashboard/src/collab-mvp-contract.ts`.

It provides:

- current Phase 1 stack status (`contract`, `installed`, or `observed`)
- TODO claim and turn-queue projections from existing dashboard data
- cytoscape-ready Git graph nodes/edges from task worktree metadata
- coordination fallback branches for active tasks that do not yet expose
  worktree metadata

## Next Implementation Steps

1. Wire `parseTrack1Frame` into the dashboard WebSocket route after the
   awareness-channel split implementation is available.
2. Add the server-side opaque Yjs relay or multiplexed WS topic selected by
   RFC 0017 Q-1.
3. Implement server-authored projection encoding for keepers, turn queue,
   activity log, tasks, and Git graph.
4. Mount CodeMirror 6 as a read-only viewer of server-authored file snapshots.
5. Render the Git graph projection through the existing cytoscape dependency.
6. Add k6/Playwright coverage for 12 peers, <50 ms median sync, and 30 FPS
   awareness coalescing.
