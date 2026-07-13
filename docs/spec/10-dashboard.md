---
status: reference
last_verified: 2026-07-13
code_refs:
  - lib/dashboard/
  - lib/server/server_dashboard_http.ml
  - dashboard/
---

# Dashboard

> Part of: [SPEC-INDEX](./SPEC-INDEX.md)

## 1. Purpose and authority

The dashboard is an observable projection and interaction surface for MASC. It
does not own Keeper lifecycle, Tool authorization, Task/Goal transitions, or
runtime selection. Writes call the same typed domain APIs used by other clients;
the dashboard never edits persistence directly.

## 2. Source projections

The UI projects source facts from:

- Keeper lanes, turns, transcripts, Jobs, and lifecycle events;
- Task and Goal versions, judgments, and evidence references;
- Board posts, comments, reactions, mentions, and LLM curation snapshots;
- Channel/Connector scope and message correlations;
- Gate pending/resolved records and LLM/operator provenance;
- Fusion panel runs, individual results, Judge results, and failures;
- Memory events and compaction/consolidation provenance;
- OAS runtime/provider/model call telemetry.

Every projection retains the source id, version, timestamp, and correlation
needed to trace it back. Missing source data renders as an explicit unavailable
or error state, never as a fabricated empty success.

## 3. Keeper chat

Keeper chat preserves the provider stream order and renders interleaved:

- user/assistant/system text;
- reasoning or thinking parts exposed by the provider contract;
- tool calls and tool results joined by typed call id;
- images, audio, voice, files, and other multimodal parts;
- Job, Fusion, and Gate references;
- errors and cancellation.

The UI does not reconstruct this order from timestamps or string prefixes. It
uses the durable sequence emitted by the turn boundary. Sending a message
appends a typed stimulus to that Keeper's lane; it does not demand an immediate
turn when the Keeper is busy.

## 4. Gate UI

The Gate view exposes the configured mode and durable request state:

- `Always_allow` dispatch evidence;
- `Auto_judge` verdict, rationale, runtime/model, and evidence;
- `Manual` pending request and explicit operator resolution.

The dashboard does not calculate risk tiers, recognize product/tool names, or
invent local vetoes. Resolving one request wakes only its originating Keeper
lane. Pending HITL does not render the Keeper or Workspace as paused.

## 5. Task, Goal, Board, and Fusion

Task and Goal controls send expected versions and display conflicts. Goal
completion shows configured LLM judgment provenance; the UI does not aggregate
votes or assign verifier authority.

Board views render exact source ordering such as recent, updated, discussed,
or voted. Semantic recommendations come from a separately persisted configured
LLM curation snapshot. Karma, flair, reputation, hot/trending formulas, and
author-status inference are not dashboard contracts.

Fusion is asynchronous. The UI shows every panel result/failure followed by the
Judge result. It never treats minimum answer count, majority, cost, or timeout
as semantic authority.

## 6. Transport isolation

HTTP snapshots use cursor-based reads. SSE/WebSocket events carry typed event
names and payload codecs shared with the backend. A slow or disconnected client
affects only that connection; it cannot block publishers, Keeper lanes, or other
clients.

Request timeouts and cache eviction are transport-local failures. They are
observed and retried by the client as appropriate, but never change Keeper
lifecycle or product state. The dashboard may cache immutable/versioned
snapshots; it must not create a second mutable SSOT.

## 7. Observability

The dashboard exposes turn duration, time-to-first-token, token throughput,
provider/model, tool latency, Job/Fusion/Gate latency, queue position, failures,
and correlation ids. Metrics explain behavior; they do not authorize it.

All error surfaces include a typed code and trace/correlation where available.
Filtering and text search are presentation functions only and do not reclassify
source state.

## 8. Required invariants

- `INV-DASH-001`: every rendered state is traceable to a typed source fact.
- `INV-DASH-002`: every mutation uses the owning domain API and expected version.
- `INV-DASH-003`: stream order preserves thinking/tool/multimodal interleaving.
- `INV-DASH-004`: connection failure is client-local.
- `INV-DASH-005`: no presentation classifier acquires runtime authority.
- `INV-DASH-006`: Gate decisions and Goal judgments display provenance.
- `INV-DASH-007`: pending HITL never becomes a Keeper/Workspace pause.

## 9. Retired surfaces

Retired contracts include Governance pages, risk-level controls, command-plane
authorization, derived Keeper phase bands, global pause controls, Karma/Flair,
reputation/quality scores, fixed hot/trending ranking, and dashboard-owned
provider capacity or cooldown gates.
